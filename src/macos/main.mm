#import <Cocoa/Cocoa.h>

#include <atomic>
#include <cstdlib>
#include <iostream>
#include <string>
#include <thread>

#include "AppWindow.h"
#include "Capture.h"
#include "DiscordPresence.h"
#include "DiscordRpc.h"
#include "LocalUiProxy.h"
#include "Log.h"
#include "MPV.h"
#include "MediaKeys.h"
#include "Net.h"
#include "NodeServer.h"
#include "Protocol.h"
#include "SelfTest.h"
#include "Settings.h"
#include "Shell.h"
#include "Splash.h"
#include "Strings.h"
#include "Tray.h"
#include "Updater.h"
#include "WebShell.h"

namespace {
std::atomic<bool> g_cleanupDone{false};
}

// Mirrors Cleanup() from src/utils/crashlog.cpp. Idempotent: called from
// application exit and from atexit.
void Cleanup() {
  if (g_cleanupDone.exchange(true)) return;

  SaveSettings();
  StopLocalUiProxy();
  ShutdownRenderer();
  CleanupMPV();
  StopNodeServer();
  RemoveTrayIcon();
  ReleaseSingleInstance();
  Discord_Shutdown();

  std::cout << "Exiting..." << std::endl;
}

int main(int argc, char *argv[]) {
  @autoreleasepool {
    int selfTestTimeout = 90;
    bool checkEndpoints = false;
    std::string capturePath;
    int captureAfter = 20;

    for (int i = 1; i < argc; i++) {
      std::string arg(argv[i]);
      if (arg.rfind("--webui-url=", 0) == 0) {
        g_webuiUrls.insert(g_webuiUrls.begin(), arg.substr(12));
      } else if (arg.rfind("--autoupdater-endpoint=", 0) == 0) {
        g_updateUrl = arg.substr(23);
      } else if (arg == "--streaming-server-disabled") {
        g_streamingServer = false;
      } else if (arg == "--autoupdater-force-full") {
        g_autoupdaterForceFull = true;
      } else if (arg == "--self-test") {
        SelfTestEnable();
      } else if (arg.rfind("--selftest-media=", 0) == 0) {
        g_selfTestMediaPath = arg.substr(17);
      } else if (arg.rfind("--selftest-timeout=", 0) == 0) {
        selfTestTimeout = std::atoi(arg.substr(19).c_str());
      } else if (arg == "--check-endpoints") {
        checkEndpoints = true;
      } else if (arg == "--no-ui-proxy") {
        g_uiProxyEnabled = false;
      } else if (arg.rfind("--capture-window=", 0) == 0) {
        capturePath = arg.substr(17);
      } else if (arg.rfind("--capture-after=", 0) == 0) {
        captureAfter = std::atoi(arg.substr(16).c_str());
      }
    }

    ResolveShellPaths(argc, argv);
    InstallCrashHandlers();
    std::atexit(Cleanup);
    LoadSettings();

    if (checkEndpoints) {
      std::string url = GetFirstReachableUrl();
      std::cout << "REACHABLE " << url << std::endl;
      return url.empty() ? 1 : 0;
    }

    if (!SelfTestEnabled()) {
      if (!AcquireSingleInstance(argc, argv)) {
        return 0;
      }
    }

    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];

    ShellInitAppDelegates();
    ShellCreateMainWindow();
    CreateSplashScreen();
    shell::UpdateTheme();
    CreateTrayIcon();

    if (!InitMPV()) {
      AppendToCrashLog("[BOOT]: mpv initialization failed");
      return 1;
    }

    if (!InitWebShell()) {
      AppendToCrashLog("[BOOT]: web shell initialization failed");
      return 1;
    }

    if (g_streamingServer) {
      StartNodeServer();
    }

    InitMediaKeys();

    if (!SelfTestEnabled()) {
      InitializeDiscord();
      g_updaterThread = std::thread(RunAutoUpdaterOnce);
      g_updaterThread.detach();
    } else {
      SelfTestBegin(g_selfTestMediaPath, selfTestTimeout);
    }

    if (!capturePath.empty()) {
      std::string path = capturePath;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(captureAfter * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), ^{
                       if (std::getenv("STREMIO_CAPTURE_HIDE_WEBVIEW")) {
                         WebShellSetHidden(true);
                       }
                       std::cout << "[CAPTURE]: WKWebView drawsBackground="
                                 << (WebShellDrawsBackground() ? "YES" : "NO") << std::endl;
                       if (const char *snapshot = std::getenv("STREMIO_CAPTURE_SNAPSHOT")) {
                         WebShellTakeSnapshot(snapshot);
                       }
                       bool ok = CaptureMainWindowToPng(path);
                       std::cout << "CAPTURE_" << (ok ? "OK " : "FAIL ") << path << std::endl;
                       dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                                      dispatch_get_main_queue(), ^{
                                        Cleanup();
                                        std::exit(ok ? 0 : 1);
                                      });
                     });
    }

    // libmpv (terminal=yes) installs its own SIGTERM/SIGINT handlers, so ours
    // must be installed after InitMPV() to take precedence.
    InstallTerminationHandler();

    [app run];

    Cleanup();
    return 0;
  }
}
