#include "SelfTest.h"

#import <AppKit/AppKit.h>

#include <unistd.h>

#include <atomic>
#include <filesystem>
#include <iostream>
#include <map>
#include <mutex>
#include <thread>

#include "AppWindow.h"
#include "Bridge.h"
#include "Log.h"
#include "MacUtil.h"
#include "Shell.h"
#include "Strings.h"
#include "WebShell.h"

#include "nlohmann/json.hpp"

static std::atomic<bool> g_selfTestMode{false};
static std::atomic<bool> g_selfTestDone{false};
static std::map<std::string, bool> g_nativeChecks;
static std::mutex g_nativeChecksMutex;

bool SelfTestEnabled() { return g_selfTestMode.load(); }

void SelfTestEnable() { g_selfTestMode = true; }

static void EmitResultsAndExit(int code) {
  if (g_selfTestDone.exchange(true)) return;

  nlohmann::json report;
  report["nativeChecks"] = g_nativeChecks;
  std::cout << "SELFTEST_RESULT " << report.dump() << std::endl;

  [NSApp stop:nil];
  // Wake the run loop so stop: takes effect, then exit with the right code.
  NSEvent *event = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                      location:NSZeroPoint
                                 modifierFlags:0
                                     timestamp:0
                                  windowNumber:0
                                       context:nil
                                       subtype:0
                                         data1:0
                                         data2:0];
  [NSApp postEvent:event atStart:NO];
  std::exit(code);
}

void SelfTestHandleEvent(const std::string &ev, const std::vector<std::string> &args) {
  if (ev == "selftest-done") {
    if (args.empty()) {
      EmitResultsAndExit(2);
      return;
    }
    try {
      nlohmann::json payload = nlohmann::json::parse(args[0]);
      bool allPass = true;
      nlohmann::json checks = nlohmann::json::object();
      if (payload.contains("checks")) {
        checks = payload["checks"];
        for (auto &[name, value] : checks.items()) {
          bool pass = value.is_boolean() ? value.get<bool>() : false;
          if (!pass) allPass = false;
          std::cout << "SELFTEST_CHECK " << name << " " << (pass ? "pass" : "fail") << std::endl;
        }
      }
      {
        std::lock_guard<std::mutex> lock(g_nativeChecksMutex);
        for (const auto &[name, pass] : g_nativeChecks) {
          std::cout << "SELFTEST_CHECK " << name << " " << (pass ? "pass" : "fail") << std::endl;
          if (!pass) allPass = false;
        }
      }
      std::cout << (allPass ? "SELFTEST_PASS" : "SELFTEST_FAIL") << std::endl;
      EmitResultsAndExit(allPass ? 0 : 1);
    } catch (const std::exception &e) {
      std::cout << "SELFTEST_FAIL could not parse result: " << e.what() << std::endl;
      EmitResultsAndExit(2);
    }
    return;
  }

  if (ev == "selftest-log") {
    if (!args.empty()) std::cout << "SELFTEST_LOG " << args[0] << std::endl;
    return;
  }

  if (ev == "selftest-native-check") {
    if (args.size() >= 2) {
      std::lock_guard<std::mutex> lock(g_nativeChecksMutex);
      g_nativeChecks[args[0]] = args[1] == "pass";
    }
    return;
  }
}

void SelfTestBegin(const std::string &mediaPath, int timeoutSeconds) {
  std::cout << "SELFTEST_BEGIN media=" << mediaPath << " timeout=" << timeoutSeconds << std::endl;

  std::string media = mediaPath;
  int timeout = timeoutSeconds > 0 ? timeoutSeconds : 90;

  std::thread([media]() {
    // Give the web view time to load the harness and finish mpv initialization,
    // then exercise the native file-drop path and check the renderer.
    for (int waited = 0; waited < 15 && !g_selfTestDone.load(); waited++) {
      std::this_thread::sleep_for(std::chrono::seconds(1));
    }
    if (g_selfTestDone.load()) return;

    {
      std::lock_guard<std::mutex> lock(g_nativeChecksMutex);
      g_nativeChecks["renderer-ready"] = RendererReady();
      g_nativeChecks["media-exists"] = FileExists(media);
    }

    // Exercise the window/tray/theme/zoom features on the main thread.
    __block std::string windowChecks;
    dispatch_sync(dispatch_get_main_queue(), ^{
      windowChecks = ShellWindowModeSelfCheck();
    });
    try {
      nlohmann::json parsed = nlohmann::json::parse(windowChecks);
      std::lock_guard<std::mutex> lock(g_nativeChecksMutex);
      for (auto &[name, value] : parsed.items()) {
        g_nativeChecks[name] = value.is_boolean() ? value.get<bool>() : false;
      }
    } catch (const std::exception &e) {
      std::lock_guard<std::mutex> lock(g_nativeChecksMutex);
      g_nativeChecks["window-mode-self-check"] = false;
    }

    // Native-initiated subtitle drop (portable_config path not required).
    std::filesystem::path subtitlePath =
        std::filesystem::path(NSTemporaryDirectory().UTF8String) / "stremio-selftest.srt";
    const char *srt = "1\n00:00:00,000 --> 00:00:05,000\nStremio self test\n";
    WriteFileUtf8(subtitlePath.string(), srt);
    dispatch_async(dispatch_get_main_queue(), ^{
      HandleDroppedFilePath(subtitlePath.string());
    });
    {
      std::lock_guard<std::mutex> lock(g_nativeChecksMutex);
      g_nativeChecks["subtitle-drop-dispatched"] = true;
    }
  }).detach();

  std::thread([timeout]() {
    int waited = 0;
    while (!g_selfTestDone.load() && waited < timeout) {
      std::this_thread::sleep_for(std::chrono::seconds(1));
      waited++;
    }
    if (!g_selfTestDone.load()) {
      std::cout << "SELFTEST_FAIL timeout after " << timeout << "s" << std::endl;
      EmitResultsAndExit(3);
    }
  }).detach();
}
