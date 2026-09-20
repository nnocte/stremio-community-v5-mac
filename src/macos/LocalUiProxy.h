#ifndef LOCALUIPROXY_H
#define LOCALUIPROXY_H

#include <string>

// WKWebView blocks requests to http://127.0.0.1 from an https page (mixed
// content), while Chromium-based shells (WebView2) allow it. The Stremio web UI
// must reach the local streaming server (http://127.0.0.1:11470) and play local
// files, so the macOS port serves the UI through a loopback reverse proxy:
// the page origin becomes http://127.0.0.1:<port>, which makes the streaming
// server requests same-scheme and allowed.
//
// Returns the local base URL (e.g. "http://127.0.0.1:51234") or an empty
// string when the proxy could not be started.
std::string StartLocalUiProxy(const std::string &upstreamBaseUrl);
void StopLocalUiProxy();
std::string LocalUiProxyBaseUrl();

#endif // LOCALUIPROXY_H
