#ifndef SHELL_H
#define SHELL_H

// Shared shell state for the macOS build.
//
// Mirrors src/core/globals.h of the Windows build, minus the Win32 handles.
// All strings are UTF-8 std::string; conversion to NSString happens in the
// Objective-C++ layer (MacUtil.h).

#include <atomic>
#include <chrono>
#include <filesystem>
#include <map>
#include <set>
#include <string>
#include <thread>
#include <unordered_set>
#include <vector>

#include "nlohmann/json.hpp"

#include "mpv/client.h"

using json = nlohmann::json;

// -----------------------------------------------------------------------------
// App info
// -----------------------------------------------------------------------------
#ifndef APP_VERSION
#define APP_VERSION "5.0.22"
#endif
#define APP_TITLE "Stremio - Freedom to Stream"
#define APP_NAME "Stremio"
#define APP_BUNDLE_ID "me.zarg.stremio.desktop"

// The community web UI talks to the streaming server on this local address
// (its StreamingServer service has the port baked in), so the shell cannot
// relocate it. Overridable only through the UI itself, not through us.
#define STREAMING_SERVER_PORT 11470
#define STREAMING_SERVER_URL "http://127.0.0.1:11470"

// -----------------------------------------------------------------------------
// Paths (resolved in Shell.mm, see docs/MACOS.md)
// -----------------------------------------------------------------------------
extern std::string g_exeDir;       // Contents/MacOS
extern std::string g_resourcesDir; // Contents/Resources
extern std::string g_configDir;    // portable_config equivalent

// -----------------------------------------------------------------------------
// Web UI / endpoints
// -----------------------------------------------------------------------------
extern std::vector<std::string> g_webuiUrls;
extern std::vector<std::string> g_domainWhitelist;
extern std::string g_updateUrl;
extern std::string g_extensionsDetailsUrl;
extern std::string g_webuiUrl;

// Command line args
extern bool g_streamingServer;
extern bool g_autoupdaterForceFull;

// -----------------------------------------------------------------------------
// mpv
// -----------------------------------------------------------------------------
extern mpv_handle *g_mpv;
extern std::set<std::string> g_observedProps;
extern bool g_initialSet;
extern std::string g_initialVO; // forced to "libmpv" on macOS (render API)
extern int g_currentVolume;
extern const std::vector<std::string> g_subtitleExtensions;

// Security: default-deny allow-lists (lowercased, utf8)
extern std::unordered_set<std::string> g_mpvCommandAllowlist;
extern std::unordered_set<std::string> g_mpvSetPropAllowlist;

// -----------------------------------------------------------------------------
// Settings (stremio-settings.ini)
// -----------------------------------------------------------------------------
extern bool g_closeOnExit;
extern bool g_useDarkTheme;
extern bool g_allowZoom;
extern bool g_isRpcOn;
extern bool g_pauseOnMinimize;
extern bool g_pauseOnLostFocus;
extern int g_thumbFastHeight;

// Window state
extern bool g_showWindow;
extern bool g_alwaysOnTop;
extern bool g_isFullscreen;
extern bool g_isPipMode;

// -----------------------------------------------------------------------------
// App ready / outbound queue
// -----------------------------------------------------------------------------
extern std::vector<nlohmann::json> g_outboundMessages;
extern std::string g_launchProtocol;
extern std::atomic<bool> g_isAppReady;
extern std::atomic<bool> g_waitStarted;

// -----------------------------------------------------------------------------
// Extensions
// -----------------------------------------------------------------------------
extern std::map<std::string, std::string> g_extensionMap; // folder name => id
extern std::vector<std::string> g_scriptQueue;

// -----------------------------------------------------------------------------
// Updater
// -----------------------------------------------------------------------------
extern std::atomic_bool g_updaterRunning;
extern std::filesystem::path g_installerPath;
extern std::thread g_updaterThread;
extern const char *public_key_pem;

// -----------------------------------------------------------------------------
// Node server / self test
// -----------------------------------------------------------------------------
extern std::atomic_bool g_nodeRunning;
extern std::string g_selfTestMediaPath;
extern bool g_uiProxyEnabled;

// -----------------------------------------------------------------------------
// ThumbFast hover suppression
// -----------------------------------------------------------------------------
extern std::atomic<bool> g_ignoreHover;
extern std::chrono::steady_clock::time_point g_ignoreUntil;
constexpr std::chrono::milliseconds IGNORE_DURATION(200);

// -----------------------------------------------------------------------------
// Path resolution (called once from main with the raw argv)
// -----------------------------------------------------------------------------
void ResolveShellPaths(int argc, char *argv[]);

// -----------------------------------------------------------------------------
// Platform interface, implemented by the Objective-C++ layer
// -----------------------------------------------------------------------------
namespace shell {

void SendToWeb(const std::string &jsonPayload); // -> window.chrome.webview message
void Navigate(const std::string &url);          // load url in the shell web view
void Reload(bool clearCache);                   // F5 / Ctrl+F5 equivalent
void PostAppReady();                            // flush outbound queue + launch arg
void SetPip(bool enable);
void ToggleFullScreen(bool enable);
void SetAlwaysOnTop(bool on);
void ShowMainWindow();
void HideMainWindow();
void OpenExternal(const std::string &uri);
void StartDrag();
void UpdateTheme();
void UpdateTray();
void Quit();

} // namespace shell

// -----------------------------------------------------------------------------
// Shared functions living in the Objective-C++ layer
// -----------------------------------------------------------------------------
bool InitWebShell();           // creates WKWebView and wires the JS bridge
void RefreshWebFromNative();   // entry point used by Bridge
void HandleLaunchProtocol(const std::string &arg);
void HandleMpvEvents();        // mpv wakeup -> main queue -> here
void ShutdownRenderer();       // frees the mpv render context (main thread)
bool RendererReady();          // true once the mpv render context exists
bool VerifyUpdateSignature(const std::string &data, const std::string &signatureBase64);
std::string Sha256File(const std::filesystem::path &file);

#endif // SHELL_H
