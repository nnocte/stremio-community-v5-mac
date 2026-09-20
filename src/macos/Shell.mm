#include "Shell.h"
#include "Log.h"
#include "MacUtil.h"

#import <Foundation/Foundation.h>

#include <cstdlib>
#include <iostream>

// -----------------------------------------------------------------------------
// Paths
// -----------------------------------------------------------------------------
std::string g_exeDir;
std::string g_resourcesDir;
std::string g_configDir;

// -----------------------------------------------------------------------------
// Web UI / endpoints
// -----------------------------------------------------------------------------
std::vector<std::string> g_webuiUrls = {
    "https://stremio.zarg.me/",
    "https://zaarrg.github.io/stremio-web-shell-fixes/",
    "https://web.stremio.com/"};

std::vector<std::string> g_domainWhitelist;
std::string g_updateUrl =
    "https://raw.githubusercontent.com/Zaarrg/stremio-desktop-v5/refs/heads/webview-windows/version/version.json";
std::string g_extensionsDetailsUrl =
    "https://raw.githubusercontent.com/Zaarrg/stremio-desktop-v5/refs/heads/webview-windows/extensions/extensions.json";
std::string g_webuiUrl;

bool g_streamingServer = true;
bool g_autoupdaterForceFull = false;

// -----------------------------------------------------------------------------
// mpv
// -----------------------------------------------------------------------------
mpv_handle *g_mpv = nullptr;
std::set<std::string> g_observedProps;
bool g_initialSet = false;
// The render API requires vo=libmpv; the web UI must never change it (see MPV.mm).
std::string g_initialVO = "libmpv";
int g_currentVolume = 50;
const std::vector<std::string> g_subtitleExtensions = {
    ".srt", ".ass", ".ssa", ".sub", ".vtt", ".ttml",
    ".dfxp", ".smi", ".sami", ".sup", ".scc",
    ".xml", ".lrc", ".pjs", ".mpl", ".usf",
    ".qtvr"};

std::unordered_set<std::string> g_mpvCommandAllowlist;
std::unordered_set<std::string> g_mpvSetPropAllowlist;

// -----------------------------------------------------------------------------
// Settings
// -----------------------------------------------------------------------------
bool g_closeOnExit = false;
bool g_useDarkTheme = true;
bool g_allowZoom = false;
bool g_isRpcOn = true;
bool g_pauseOnMinimize = true;
bool g_pauseOnLostFocus = false;
int g_thumbFastHeight = 0;

bool g_showWindow = true;
bool g_alwaysOnTop = false;
bool g_isFullscreen = false;
bool g_isPipMode = false;

// -----------------------------------------------------------------------------
// App ready / outbound queue
// -----------------------------------------------------------------------------
std::vector<nlohmann::json> g_outboundMessages;
std::string g_launchProtocol;
std::atomic<bool> g_isAppReady = false;
std::atomic<bool> g_waitStarted(false);

// -----------------------------------------------------------------------------
// Extensions
// -----------------------------------------------------------------------------
std::map<std::string, std::string> g_extensionMap;
std::vector<std::string> g_scriptQueue;

// -----------------------------------------------------------------------------
// Updater
// -----------------------------------------------------------------------------
std::atomic_bool g_updaterRunning = false;
std::filesystem::path g_installerPath;
std::thread g_updaterThread;
const char *public_key_pem = R"(-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAoXoJRQ81xOT3Gx6+hsWM
ZiD4PwtLdxxNhEdL/iK0yp6AdO/L0kcSHk9YCPPx0XPK9sssjSV5vCbNE/2IJxnh
/mV+3GAMmXgMvTL+DZgrHafnxe1K50M+8Z2z+uM5YC9XDLppgnC6OrUjwRqNHrKI
T1vcgKf16e/TdKj8xlgadoHBECjv6dr87nbHW115bw8PVn2tSk/zC+QdUud+p6KV
zA6+FT9ZpHJvdS3R0V0l7snr2cwapXF6J36aLGjJ7UviRFVWEEsQaKtAAtTTBzdD
4B9FJ2IJb/ifdnVzeuNTDYApCSE1F89XFWN9FoDyw7Jkk+7u4rsKjpcnCDTd9ziG
kwIDAQAB
-----END PUBLIC KEY-----)";

// -----------------------------------------------------------------------------
// ThumbFast
// -----------------------------------------------------------------------------
std::atomic<bool> g_ignoreHover(false);
std::chrono::steady_clock::time_point g_ignoreUntil;

// -----------------------------------------------------------------------------
// Self test
// -----------------------------------------------------------------------------
std::string g_selfTestMediaPath;

// Serve the web UI through the loopback proxy by default (see LocalUiProxy.h).
bool g_uiProxyEnabled = true;

// -----------------------------------------------------------------------------
// Path resolution
// -----------------------------------------------------------------------------
static std::string HomeDirectory() {
  const char *home = std::getenv("HOME");
  return home ? std::string(home) : std::string();
}

static bool IsDirectory(const std::string &path) {
  std::error_code ec;
  return std::filesystem::is_directory(path, ec);
}

static void EnsureDirectory(const std::string &path) {
  std::error_code ec;
  std::filesystem::create_directories(path, ec);
  if (ec) {
    std::cerr << "[SHELL]: Failed to create directory " << path << ": " << ec.message() << "\n";
  }
}

// Resolution order (documented in docs/MACOS.md):
//   1. --portable-config=<path>
//   2. $STREMIO_PORTABLE_CONFIG
//   3. <bundle parent>/portable_config (truly portable .app)
//   4. ~/Library/Application Support/Stremio/portable_config (default)
void ResolveShellPaths(int argc, char *argv[]) {
  NSString *exePath = [[NSBundle mainBundle] executablePath];
  if (exePath) {
    g_exeDir = [[exePath stringByDeletingLastPathComponent] UTF8String];
  } else if (argc > 0) {
    g_exeDir = std::filesystem::path(argv[0]).parent_path().string();
  }

  NSString *resourcePath = [[NSBundle mainBundle] resourcePath];
  g_resourcesDir = resourcePath ? NsToUtf8(resourcePath) : g_exeDir;

  std::string portableOverride;
  for (int i = 1; i < argc; i++) {
    std::string arg(argv[i]);
    if (arg.rfind("--portable-config=", 0) == 0) {
      portableOverride = arg.substr(18);
    }
  }
  if (portableOverride.empty()) {
    if (const char *env = std::getenv("STREMIO_PORTABLE_CONFIG")) {
      portableOverride = env;
    }
  }

  if (!portableOverride.empty()) {
    g_configDir = portableOverride;
  } else {
    // <...>/Stremio.app/Contents/MacOS -> <...>/Stremio.app -> <...>
    std::filesystem::path bundleParent =
        std::filesystem::path(g_exeDir).parent_path().parent_path().parent_path();
    std::filesystem::path portable = bundleParent / "portable_config";
    if (IsDirectory(portable.string())) {
      g_configDir = portable.string();
    } else {
      g_configDir = HomeDirectory() + "/Library/Application Support/Stremio/portable_config";
    }
  }
  bool configExisted = IsDirectory(g_configDir);
  EnsureDirectory(g_configDir);

  // First run: seed the default settings from the bundled template (the Windows
  // distribution ships the same file as portable_config/stremio-settings.ini).
  if (!configExisted) {
    std::filesystem::path templateIni =
        std::filesystem::path(g_resourcesDir) / "portable_config" / "stremio-settings.ini";
    std::error_code copyEc;
    if (std::filesystem::is_regular_file(templateIni, copyEc)) {
      std::filesystem::copy_file(templateIni,
                                 std::filesystem::path(g_configDir) / "stremio-settings.ini",
                                 std::filesystem::copy_options::skip_existing, copyEc);
    }
  }

  std::cout << "[SHELL]: exeDir=" << g_exeDir << "\n"
            << "[SHELL]: resources=" << g_resourcesDir << "\n"
            << "[SHELL]: configDir=" << g_configDir << std::endl;
}
