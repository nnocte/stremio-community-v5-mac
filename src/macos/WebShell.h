#ifndef WEBSHELL_H
#define WEBSHELL_H

#include <string>

// WKWebView equivalent of src/webview/webview.cpp + src/utils/extensions.cpp.
bool InitWebShell(); // main thread, after the main window exists
void RefreshWebFromNative();
void WaitAndRefreshIfNeeded();

// The web view is not always reachable (offline start, captive portal, ...).
void ShellDidResolveWebUiUrl(const std::string &url);

// Extension helpers (PremID / Stylus flows), ported from the Windows build.
bool HandleExtensions(const std::string &finalUri);
bool HandlePremidLogin(const std::string &finalUri);
bool HandleStylusUsoInstall(const std::string &finalUri);

// Handles a dropped/opened local file (subtitle -> mpv sub-add, otherwise the
// web UI decides; parity with the WebView2 file:// path).
void HandleDroppedFilePath(const std::string &filePath);

// Diagnostic: hides/shows the web view (used by the window capture tool).
void WebShellSetHidden(bool hidden);
void WebShellTakeSnapshot(const std::string &path);
bool WebShellDrawsBackground();

// Page zoom (View menu), only effective when AllowZoom=1 in the settings.
void WebShellSetPageZoom(double zoom);
double WebShellPageZoom(void);
// Main-thread variant used by the self test.
void WebShellApplyPageZoom(double zoom);

#endif // WEBSHELL_H
