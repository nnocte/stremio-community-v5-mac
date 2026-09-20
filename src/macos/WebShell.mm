#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

#import "AppWindow.h"

#include <atomic>
#include <cmath>
#include <filesystem>
#include <iostream>
#include <thread>

#include "Bridge.h"
#include "LocalUiProxy.h"
#include "Log.h"
#include "MacUtil.h"
#include "MPV.h"
#include "Net.h"
#include "SelfTest.h"
#include "Shell.h"
#include "Splash.h"
#include "Strings.h"
#include "WebShell.h"

// -----------------------------------------------------------------------------
// Injected scripts
//
// The bootstrap provides the WebView2 API surface (`window.chrome.webview`,
// `window.qt.webChannelTransport`) on top of WKWebView's message handlers, so
// the unmodified stremio-web-shell bundle picks its Qt transport path exactly
// like it does on Windows.
// -----------------------------------------------------------------------------
static const char *kShellBootstrapScript = R"JS(
(function () {
  try {
    if (window.__stremioShellBridgeInstalled) return;
    window.__stremioShellBridgeInstalled = true;

    var listeners = [];
    var transport = {
      send: function (message) {
        try {
          window.webkit.messageHandlers.stremioShell.postMessage(String(message));
        } catch (e) {
          console.error('shell bridge send failed', e);
        }
      },
      onmessage: null
    };

    window.chrome = window.chrome || {};
    window.chrome.webview = {
      postMessage: function (message) { transport.send(message); },
      addEventListener: function (type, listener) {
        if (type === 'message' && typeof listener === 'function') listeners.push(listener);
      },
      removeEventListener: function (type, listener) {
        if (type !== 'message') return;
        var index = listeners.indexOf(listener);
        if (index >= 0) listeners.splice(index, 1);
      }
    };

    window.__stremioNativeDispatch = function (text) {
      try {
        window.webkit.messageHandlers.stremioConsole.postMessage('native->js: ' + String(text).slice(0, 120));
      } catch (e) {}
      var event = { type: 'message', data: text, source: window };
      for (var i = 0; i < listeners.length; i++) {
        try { listeners[i](event); } catch (e) { console.error('shell listener failed', e); }
      }
      if (typeof transport.onmessage === 'function') {
        try { transport.onmessage(event); } catch (e) { console.error('shell onmessage failed', e); }
      }
    };

    window.qt = { webChannelTransport: transport };

    try {
      window.webkit.messageHandlers.stremioConsole.postMessage('bootstrap installed');
    } catch (e) {}

    // The Windows shell calls initShellComm() from window.onload; do the same
    // here, but with addEventListener so page code cannot overwrite the hook.
    // This must live in the bootstrap because it defines window.qt, which makes
    // the Windows EXEC_SHELL_SCRIPT skip its own onload hook.
    var kickShellComm = function () {
      if (typeof window.initShellComm === 'function') {
        try {
          window.initShellComm();
        } catch (e) {
          console.error('shell initShellComm failed', e);
        }
        return;
      }
      // Same app-error the Windows shell reports when the shell JS is missing.
      try {
        window.chrome.webview.postMessage(JSON.stringify({
          type: 6,
          object: 'transport',
          method: 'handleInboundJSON',
          id: 888,
          args: ['app-error', ['shellComm']]
        }));
      } catch (e) {}
    };
    if (document.readyState === 'complete') {
      setTimeout(kickShellComm, 0);
    } else {
      window.addEventListener('load', kickShellComm, { once: true });
    }
  } catch (e) {
    console.error('shell bootstrap failed', e);
  }
})();
)JS";

// Same script as src/webview/webview.cpp (EXEC_SHELL_SCRIPT).
static const char *kExecShellScript = R"JS(
try {
    console.log('Shell JS injected');
    if (window.self === window.top && !window.qt) {
      window.qt = {
        webChannelTransport: {
          send: window.chrome.webview.postMessage,
          onmessage: (ev) => {
            // Will be overwritten by ShellTransport
            console.log('Received message from WebView2:', ev);
          }
        }
      };

      window.chrome.webview.addEventListener('message', (ev) => {
        window.qt.webChannelTransport.onmessage(ev);
      });

      window.onload = () => {
        try {
          initShellComm();
        } catch (e) {
            const errorMessage = {
              type: 6,
              object: "transport",
              method: "handleInboundJSON",
              id: 888,
              args: [
                "app-error",
                [ "shellComm" ]
              ]
            };
          window.chrome.webview.postMessage(JSON.stringify(errorMessage));
        }
      };
    }
} catch(e) {
    console.error("Error exec initShellComm:", e);
    const errorMessage = {
      type: 6,
      object: "transport",
      method: "handleInboundJSON",
      id: 888,
      args: [
        "app-error",
        [ "shellComm" ]
      ]
    };
    if(window.chrome && window.chrome.webview && window.chrome.webview.postMessage) {
        window.chrome.webview.postMessage(JSON.stringify(errorMessage));
    }
};
)JS";

// Same script as src/webview/webview.cpp (INJECTED_KEYDOWN_SCRIPT).
static const char *kInjectedKeydownScript = R"JS(
(function() {
    window.addEventListener('keydown', function(event) {
        if (event.code === 'F5') {
            event.preventDefault();
            const ctrlPressed = event.ctrlKey || event.metaKey;
            const msg = {
              type: 6,
              object: "transport",
              method: "handleInboundJSON",
              id: 999,
              args: [
                "refresh",
                [ ctrlPressed ? "all" : "no" ]
              ]
            };
            window.chrome.webview.postMessage(JSON.stringify(msg));
        }
    });
})();
)JS";

// Same script as src/webview/webview.cpp (INJECTED_BUTTON_SCRIPT).
static const char *kInjectedButtonScript = R"JS(
(function() {
  if (document.getElementById('goBackStremioBtn')) return;
  var btn = document.createElement('button');
  btn.id = 'goBackStremioBtn';
  btn.style.position = 'fixed';
  btn.style.bottom = '15px';
  btn.style.right = '15px';
  btn.style.zIndex = '9999';
  btn.style.backgroundColor = '#121024';
  btn.style.color = 'white';
  btn.style.border = 'none';
  btn.style.borderRadius = '30px';
  btn.style.padding = '12px 20px';
  btn.style.fontSize = '16px';
  btn.style.fontWeight = 'bold';
  btn.style.display = 'flex';
  btn.style.alignItems = 'center';
  btn.style.boxShadow = '0 4px 6px rgba(0,0,0,0.1)';
  btn.style.cursor = 'pointer';
  btn.style.transition = 'background-color 0.3s ease';

  btn.addEventListener('mouseenter', function() { btn.style.backgroundColor = '#211e39'; });
  btn.addEventListener('mouseleave', function() { btn.style.backgroundColor = '#121024'; });

  var img = document.createElement('img');
  img.src = 'https://stremio.zarg.me/images/stremio_symbol.png';
  img.alt = 'Logo';
  img.style.height = '24px';
  img.style.width = '24px';
  img.style.marginRight = '8px';
  img.addEventListener('error', function() { img.style.display = 'none'; });

  var txt = document.createElement('span');
  txt.textContent = 'Back to Stremio';

  btn.appendChild(img);
  btn.appendChild(txt);

  btn.addEventListener('click', function() {
    const payload = {
      type: 6,
      object: "transport",
      method: "handleInboundJSON",
      id: 666,
      args: [ "navigate", [ "home" ] ]
    };
    window.chrome.webview.postMessage(JSON.stringify(payload));
  });

  document.body.appendChild(btn);
})();
)JS";

#ifdef DEBUG_LOG
// Forwards page console output to the native log (DEBUG_LOG builds expose
// devtools like the WebView2 build; this makes the logs equally useful).
static const char *kConsoleForwardScript = R"JS(
(function () {
  if (window.__stremioConsoleForwarded) return;
  window.__stremioConsoleForwarded = true;
  ['log', 'warn', 'error', 'info'].forEach(function (level) {
    var original = console[level];
    console[level] = function () {
      try {
        var parts = Array.prototype.map.call(arguments, function (a) {
          try {
            if (a instanceof Error) return a.name + ': ' + a.message + '\n' + (a.stack || '');
            return typeof a === 'string' ? a : JSON.stringify(a);
          } catch (e) { return String(a); }
        });
        window.webkit.messageHandlers.stremioConsole.postMessage(level + ': ' + parts.join(' '));
      } catch (e) {}
      original.apply(console, arguments);
    };
  });
})();
)JS";
#endif

// Forward declaration (defined below; used by the navigation delegate).
void HandleDroppedFileUrl(NSURL *url);

// -----------------------------------------------------------------------------
// State
// -----------------------------------------------------------------------------
static WKWebView *g_webView = nil;
static WKWebViewConfiguration *g_config = nil;

static std::string g_resolvedWebUiUrl;
static bool g_didNavigate = false;
static std::atomic<bool> g_extensionsReady{false};
static bool g_extensionsStarted = false;

namespace {

NSString *Script(const char *source) {
  return [NSString stringWithUTF8String:source];
}

void Evaluate(const std::string &javascript) {
  if (!g_webView) return;
  NSString *js = Utf8ToNs(javascript);
  [g_webView evaluateJavaScript:js
              completionHandler:^(id _Nullable result, NSError *_Nullable error) {
                (void)result;
#ifdef DEBUG_LOG
                if (error) {
                  std::cout << "[WEBVIEW]: evaluateJavaScript error: "
                            << NsToUtf8(error.localizedDescription) << std::endl;
                }
#else
                (void)error;
#endif
              }];
}

void MaybeNavigateToWebUi();

} // namespace

// -----------------------------------------------------------------------------
// Script message handler (avoids the WKUserContentController retain cycle)
// -----------------------------------------------------------------------------
@interface ScriptMessageProxy : NSObject <WKScriptMessageHandler>
@property(nonatomic, weak) id<WKScriptMessageHandler> target;
- (instancetype)initWithTarget:(id<WKScriptMessageHandler>)target;
@end

@implementation ScriptMessageProxy
- (instancetype)initWithTarget:(id<WKScriptMessageHandler>)target {
  self = [super init];
  if (self) _target = target;
  return self;
}
- (void)userContentController:(WKUserContentController *)controller
      didReceiveScriptMessage:(WKScriptMessage *)message {
  id<WKScriptMessageHandler> target = self.target;
  if (target) [target userContentController:controller didReceiveScriptMessage:message];
}
@end

// -----------------------------------------------------------------------------
// Navigation / UI delegate
// -----------------------------------------------------------------------------
@interface ShellWebController : NSObject <WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate>
@end

@implementation ShellWebController

- (void)userContentController:(WKUserContentController *) __unused controller
      didReceiveScriptMessage:(WKScriptMessage *)message {
  if (![message.body isKindOfClass:[NSString class]]) return;
  if ([message.name isEqualToString:@"stremioConsole"]) {
    std::cout << "[JS console] " << NsToUtf8((NSString *)message.body) << std::endl;
    return;
  }
  HandleInboundJSON(NsToUtf8((NSString *)message.body));
}

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
  NSURL *url = navigationAction.request.URL;
  NSString *scheme = url.scheme.lowercaseString ?: @"";
  std::string absolute = NsToUtf8(url.absoluteString ?: @"");

  // window.open / target=_blank: same handling as the WebView2 NewWindowRequested path.
  if (navigationAction.targetFrame == nil) {
    [self handleNewWindow:url];
    decisionHandler(WKNavigationActionPolicyCancel);
    return;
  }

  static NSSet<NSString *> *allowedSchemes = [NSSet setWithObjects:@"about", @"data", @"blob",
                                                                       @"javascript", @"file",
                                                                       @"webkit-extension",
                                                                       @"chrome-extension", nil];
  if ([allowedSchemes containsObject:scheme] || URLContainsAny(absolute)) {
    decisionHandler(WKNavigationActionPolicyAllow);
    return;
  }

  // Everything else opens in the default browser (parity with NavigationStarting).
  decisionHandler(WKNavigationActionPolicyCancel);
  shell::OpenExternal(absolute);
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
  std::string current = NsToUtf8(webView.URL.absoluteString ?: @"");
  std::cout << "[WEBVIEW]: Navigation complete: " << current << std::endl;

  if (current.find(g_webuiUrl) == std::string::npos) {
    Evaluate(kInjectedButtonScript);
  }
  Evaluate(kExecShellScript);

#ifdef DEBUG_LOG
  [webView evaluateJavaScript:@"JSON.stringify({chrome: typeof window.chrome, qt: typeof window.qt, initShellComm: typeof window.initShellComm, url: location.href})"
            completionHandler:^(id result, NSError *error) {
              std::cout << "[WEBVIEW]: page state: "
                        << (result ? NsToUtf8([result description]) : "n/a")
                        << (error ? (" error: " + NsToUtf8(error.localizedDescription)) : "")
                        << std::endl;
            }];
#endif

  if (!g_scriptQueue.empty()) {
    for (const auto &script : g_scriptQueue) {
      Evaluate(script);
    }
    g_scriptQueue.clear();
  }
}

- (void)webView:(WKWebView *)webView
    didFailProvisionalNavigation:(WKNavigation *)navigation
                       withError:(NSError *)error {
  [self handleNavigationFailure:webView error:error];
}

- (void)webView:(WKWebView *)webView
    didFailNavigation:(WKNavigation *)navigation
            withError:(NSError *)error {
  [self handleNavigationFailure:webView error:error];
}

- (void)handleNavigationFailure:(WKWebView *)webView error:(NSError *)error {
  std::string current = NsToUtf8(webView.URL.absoluteString ?: @"");
  std::cout << "[WEBVIEW]: Navigation failed: " << NsToUtf8(error.localizedDescription)
            << std::endl;

  if (!g_isAppReady && !g_waitStarted.exchange(true)) {
    WaitAndRefreshIfNeeded();
  }
  HandleExtensions(current);
}

- (WKWebView *)webView:(WKWebView *) __unused webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)navigationAction
                    windowFeatures:(WKWindowFeatures *)windowFeatures {
  [self handleNewWindow:navigationAction.request.URL];
  return nil;
}

- (void)handleNewWindow:(NSURL *)url {
  if (!url) return;

  if ([url.scheme isEqualToString:@"file"]) {
    HandleDroppedFileUrl(url);
    return;
  }

  std::string absolute = NsToUtf8(url.absoluteString ?: @"");
  if (URLContainsAny(absolute)) {
    [g_webView loadRequest:[NSURLRequest requestWithURL:url]];
    return;
  }
  shell::OpenExternal(absolute);
}

// Context menus: keep only clipboard actions for editable targets and Back for
// extension pages (same filtering as the WebView2 build).
- (void)webView:(WKWebView *)webView willOpenMenu:(NSMenu *)menu withEvent:(NSEvent *)event {
#ifdef DEBUG_LOG
  return;
#else
  std::string uri = NsToUtf8(webView.URL.absoluteString ?: @"");
  bool isExtensionUrl = uri.rfind("webkit-extension://", 0) == 0 ||
                        uri.rfind("chrome-extension://", 0) == 0;

  bool isEditable = false;
  for (NSMenuItem *item in menu.itemArray) {
    if (item.action == @selector(cut:) || item.action == @selector(paste:) ||
        item.action == @selector(selectAll:)) {
      isEditable = true;
      break;
    }
  }

  NSSet<NSString *> *editableSelectors = [NSSet setWithObjects:@"cut:", @"copy:", @"paste:",
                                                                   @"pasteAsPlainText:",
                                                                   @"selectAll:", nil];
  NSSet<NSString *> *viewerSelectors = [NSSet setWithObjects:@"goBack:", nil];

  NSMutableArray<NSMenuItem *> *remove = [NSMutableArray array];
  for (NSMenuItem *item in menu.itemArray) {
    if (item.isSeparatorItem) {
      [remove addObject:item];
      continue;
    }
    NSString *selectorName = item.action ? NSStringFromSelector(item.action) : @"";
    bool keep = isEditable ? [editableSelectors containsObject:selectorName]
                           : (isExtensionUrl && [viewerSelectors containsObject:selectorName]);
    if (!keep) [remove addObject:item];
  }
  for (NSMenuItem *item in remove) {
    [menu removeItem:item];
  }

  while (menu.numberOfItems > 0 && [menu itemAtIndex:0].isSeparatorItem) {
    [menu removeItemAtIndex:0];
  }
  while (menu.numberOfItems > 0 && [menu itemAtIndex:menu.numberOfItems - 1].isSeparatorItem) {
    [menu removeItemAtIndex:menu.numberOfItems - 1];
  }
#endif
}

@end

// -----------------------------------------------------------------------------
// File drop handling (parity with the WebView2 NewWindowRequested file:// path)
// -----------------------------------------------------------------------------
void HandleDroppedFileUrl(NSURL *url) {
  std::string utf8FileUrlPath = NsToUtf8(url.path ?: @"");
  std::string decodedFilePath = decodeURIComponent(utf8FileUrlPath);

  std::filesystem::path fsPath(decodedFilePath);
  std::string baseName = fsPath.filename().string();

  if (isSubtitle(decodedFilePath)) {
    std::vector<std::string> subaddArgs = {"sub-add", decodedFilePath, "select",
                                           baseName + " External", "Other Tracks"};
    HandleEvent("mpv-command", subaddArgs);
    json j;
    j["type"] = "SubtitleDropped";
    j["path"] = utf8FileUrlPath;
    SendToJS("SubtitleDropped", j);
    return;
  }

  json j;
  j["type"] = "FileDropped";
  j["path"] = FilePathToFileUrl(decodedFilePath);
  SendToJS("FileDropped", j);
}

void HandleDroppedFilePath(const std::string &filePath) {
  if (filePath.empty()) return;
  NSURL *url = [NSURL fileURLWithPath:Utf8ToNs(filePath)];
  if (url) HandleDroppedFileUrl(url);
}

// -----------------------------------------------------------------------------
// Launch protocol (stremio:// / magnet: / files) - the WM_COPYDATA equivalent
// -----------------------------------------------------------------------------
void HandleLaunchProtocol(const std::string &arg) {
  if (arg.empty()) return;

  if (FileExists(arg)) {
    size_t dotPos = arg.find_last_of('.');
    std::string extension = dotPos != std::string::npos ? ToLowerStr(arg.substr(dotPos)) : "";

    if (extension == ".torrent") {
      std::string fileData;
      if (!ReadFileUtf8(arg, fileData)) {
        std::cerr << "[LAUNCH]: Could not open torrent file " << arg << "\n";
        return;
      }
      json j;
      j["type"] = "OpenTorrent";
      j["data"] = json::array();
      for (unsigned char c : fileData) j["data"].push_back((int)c);
      SendToJS("OpenTorrent", j);
    } else {
      json j;
      j["type"] = "OpenFile";
      j["path"] = FilePathToFileUrl(arg);
      SendToJS("OpenFile", j);
    }
    return;
  }

  if (arg.rfind("stremio://detail", 0) == 0) {
    json j;
    j["type"] = "ReplaceLocation";
    j["path"] = arg;
    SendToJS("ReplaceLocation", j);
    return;
  }
  if (arg.rfind("stremio://", 0) == 0) {
    json j;
    j["type"] = "AddonInstall";
    j["path"] = arg;
    SendToJS("AddonInstall", j);
    return;
  }
  if (arg.rfind("magnet:", 0) == 0) {
    json j;
    j["type"] = "OpenTorrent";
    j["magnet"] = arg;
    SendToJS("OpenTorrent", j);
    return;
  }

  std::cout << "[LAUNCH]: Unhandled argument " << arg << std::endl;
}

// -----------------------------------------------------------------------------
// Platform interface used by Bridge.cpp
// -----------------------------------------------------------------------------
namespace shell {

void SendToWeb(const std::string &jsonPayload) {
  // May be called from background threads (mpv node thread, updater, ...).
  std::string payload = jsonPayload;
  dispatch_async(dispatch_get_main_queue(), ^{
    std::string quoted = json(payload).dump(); // valid JS string literal
    Evaluate("window.__stremioNativeDispatch(" + quoted + ");");
  });
}

void Navigate(const std::string &url) {
  std::string target = url;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!g_webView) return;
    NSURL *nsurl = [NSURL URLWithString:Utf8ToNs(target)];
    if (!nsurl) {
      AppendToCrashLog("[WEBVIEW]: Invalid navigation url " + target);
      return;
    }
    std::cout << "[WEBVIEW]: Navigating to " << target << std::endl;
    if (nsurl.isFileURL) {
      [g_webView loadFileURL:nsurl
          allowingReadAccessToURL:[nsurl URLByDeletingLastPathComponent]];
    } else {
      [g_webView loadRequest:[NSURLRequest requestWithURL:nsurl]];
    }
  });
}

void Reload(bool clearCache) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!g_webView) return;
    if (!clearCache) {
      [g_webView reload];
      return;
    }

    std::cout << "[BROWSER]: Clearing browser cache" << std::endl;
    NSSet<NSString *> *types = [NSSet setWithObjects:WKWebsiteDataTypeDiskCache,
                                                      WKWebsiteDataTypeMemoryCache,
                                                      WKWebsiteDataTypeServiceWorkerRegistrations,
                                                      WKWebsiteDataTypeIndexedDBDatabases,
                                                      WKWebsiteDataTypeFileSystem, nil];
    [[WKWebsiteDataStore defaultDataStore]
        removeDataOfTypes:types
           modifiedSince:[NSDate dateWithTimeIntervalSince1970:0]
       completionHandler:^{
         std::cout << "[BROWSER]: Cleared browser cache successfully" << std::endl;
         [g_webView reload];
       }];
  });
}

} // namespace shell

bool WebShellDrawsBackground() {
  id value = [g_webView valueForKey:@"drawsBackground"];
  return value ? [value boolValue] : true;
}

void WebShellTakeSnapshot(const std::string &path) {
  std::string target = path; // blocks capture C++ objects by value
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!g_webView) return;
    WKSnapshotConfiguration *configuration = [[WKSnapshotConfiguration alloc] init];
    configuration.afterScreenUpdates = YES;
    [g_webView takeSnapshotWithConfiguration:configuration
                            completionHandler:^(NSImage *image, NSError *error) {
                              if (!image || error) {
                                std::cout << "[CAPTURE]: snapshot failed: "
                                          << NsToUtf8(error.localizedDescription ?: @"") << std::endl;
                                return;
                              }
                              NSBitmapImageRep *rep =
                                  [[NSBitmapImageRep alloc] initWithData:[image TIFFRepresentation]];
                              NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG
                                                              properties:@{}];
                              [png writeToFile:Utf8ToNs(target) atomically:YES];
                              std::cout << "[CAPTURE]: snapshot wrote " << target << std::endl;
                            }];
  });
}

void WebShellSetHidden(bool hidden) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (g_webView) g_webView.hidden = hidden;
  });
}

void RefreshWebFromNative() {
  shell::Reload(false);
}

void WebShellApplyPageZoom(double zoom) {
  if (!g_allowZoom || !g_webView) return;
  double clamped = zoom < 0.25 ? 0.25 : (zoom > 5.0 ? 5.0 : zoom);
  g_webView.pageZoom = clamped;
}

void WebShellSetPageZoom(double zoom) {
  dispatch_async(dispatch_get_main_queue(), ^{
    WebShellApplyPageZoom(zoom);
  });
}

double WebShellPageZoom(void) {
  if (!g_webView) return 1.0;
  double zoom = g_webView.pageZoom;
  return zoom > 0 ? zoom : 1.0;
}

// -----------------------------------------------------------------------------
// Web mods (portable_config/webmods/*.css, *.js)
// -----------------------------------------------------------------------------
namespace {

void SetupWebMods(WKUserContentController *userContentController) {
  std::filesystem::path root = std::filesystem::path(g_configDir) / "webmods";
  if (!DirectoryExists(root.string())) {
    std::cout << "[WEBMODS]: Folder not found: " << root << std::endl;
    return;
  }

  std::vector<std::filesystem::path> cssFiles, jsFiles;
  std::error_code ec;
  for (const auto &entry : std::filesystem::recursive_directory_iterator(root, ec)) {
    if (!entry.is_regular_file()) continue;
    std::string ext = ToLowerStr(entry.path().extension().string());
    if (ext == ".map" || ext == ".bak" || ext == ".tmp") continue;
    if (ext == ".css") cssFiles.push_back(entry.path());
    else if (ext == ".js") jsFiles.push_back(entry.path());
  }

  auto relativeName = [&](const std::filesystem::path &p) {
    std::error_code relEc;
    auto rel = std::filesystem::relative(p, root, relEc);
    return relEc ? p.filename().string() : rel.string();
  };
  auto sorter = [&](const std::filesystem::path &a, const std::filesystem::path &b) {
    return ToLowerStr(relativeName(a)) < ToLowerStr(relativeName(b));
  };
  std::sort(cssFiles.begin(), cssFiles.end(), sorter);
  std::sort(jsFiles.begin(), jsFiles.end(), sorter);

  auto makeId = [&](const std::filesystem::path &p) {
    std::string id = relativeName(p);
    for (auto &ch : id) {
      if (!std::isalnum((unsigned char)ch)) ch = '_';
    }
    return id;
  };

  for (const auto &p : cssFiles) {
    std::string content;
    if (!ReadFileUtf8(p.string(), content)) continue;
    std::string script = MakeInjectCssScript(makeId(p), content);
    [userContentController
        addUserScript:[[WKUserScript alloc] initWithSource:Utf8ToNs(script)
                                           injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                        forMainFrameOnly:NO]];
    std::cout << "[WEBMODS] CSS: " << relativeName(p) << std::endl;
  }

  for (const auto &p : jsFiles) {
    std::string content;
    if (!ReadFileUtf8(p.string(), content)) continue;
    std::string script = MakeInjectJsScript(makeId(p), content);
    [userContentController
        addUserScript:[[WKUserScript alloc] initWithSource:Utf8ToNs(script)
                                           injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                        forMainFrameOnly:NO]];
    std::cout << "[WEBMODS] JS: " << relativeName(p) << std::endl;
  }
}

} // namespace

// -----------------------------------------------------------------------------
// Extensions
// -----------------------------------------------------------------------------
namespace {

void FinishExtensionsSetup() {
  if (g_extensionsReady.exchange(true)) return;
  MaybeNavigateToWebUi();
}

void SetupExtensions() {
  std::filesystem::path root = std::filesystem::path(g_configDir) / "extensions";
  if (!DirectoryExists(root.string())) {
    std::cout << "[EXTENSIONS]: No extensions folder (" << root << ")" << std::endl;
    FinishExtensionsSetup();
    return;
  }

  if (@available(macOS 15.4, *)) {
    WKWebExtensionControllerConfiguration *controllerConfig =
        [WKWebExtensionControllerConfiguration defaultConfiguration];
    WKWebExtensionController *controller =
        [[WKWebExtensionController alloc] initWithConfiguration:controllerConfig];
    g_config.webExtensionController = controller;

    std::error_code ec;
    std::vector<std::filesystem::path> folders;
    for (const auto &entry : std::filesystem::directory_iterator(root, ec)) {
      if (entry.is_directory()) folders.push_back(entry.path());
    }
    if (folders.empty()) {
      FinishExtensionsSetup();
      return;
    }

    // WKWebExtension can only be constructed asynchronously.
    __block int pending = (int)folders.size();
    for (const auto &folder : folders) {
      std::string folderName = folder.filename().string();
      NSURL *baseUrl = [NSURL fileURLWithPath:Utf8ToNs(folder.string()) isDirectory:YES];

      [WKWebExtension extensionWithResourceBaseURL:baseUrl
                                 completionHandler:^(WKWebExtension *extension, NSError *error) {
                                   if (!extension || error) {
                                     AppendToCrashLog(
                                         "[EXTENSIONS]: Failed to load " + folderName + " => " +
                                         NsToUtf8(error.localizedDescription ?: @"unknown error"));
                                   } else {
                                     NSError *contextError = nil;
                                     WKWebExtensionContext *context =
                                         [[WKWebExtensionContext alloc] initForExtension:extension];
                                     NSError *loadError = nil;
                                     if ([controller loadExtensionContext:context error:&loadError]) {
                                       std::string identifier =
                                           NsToUtf8(context.uniqueIdentifier ?: @"");
                                       g_extensionMap[folderName] = identifier;
                                       std::cout << "[EXTENSIONS]: " << folderName << " => "
                                                 << identifier << std::endl;
                                     } else {
                                       AppendToCrashLog(
                                           "[EXTENSIONS]: load failed for " + folderName + " => " +
                                           NsToUtf8(loadError.localizedDescription ?: @"unknown error") +
                                           NsToUtf8(contextError.localizedDescription ?: @""));
                                     }
                                   }

                                   if (--pending == 0) {
                                     FinishExtensionsSetup();
                                   }
                                 }];
    }
    return;
  }

  std::cout << "[EXTENSIONS]: WKWebExtensionController requires macOS 15.4+" << std::endl;
  FinishExtensionsSetup();
}

} // namespace

bool HandleExtensions(const std::string &finalUri) {
  bool handledPremid = HandlePremidLogin(finalUri);
  bool handledStylus = HandleStylusUsoInstall(finalUri);
  return handledPremid || handledStylus;
}

bool HandlePremidLogin(const std::string &finalUri) {
  if (finalUri.rfind("https://login.premid.app", 0) == 0 &&
      finalUri.rfind("https://discord.com", 0) != 0) {
    std::string extensionId;
    for (const auto &[name, id] : g_extensionMap) {
      if (name.find("premid") != std::string::npos) {
        extensionId = id;
        break;
      }
    }
    if (extensionId.empty()) {
      std::cout << "[EXTENSIONS]: Extension id not found" << std::endl;
      shell::Navigate(g_webuiUrl);
      return true;
    }

    std::string codeParam;
    size_t codePos = finalUri.find("code=");
    if (codePos != std::string::npos) {
      codePos += 5;
      size_t ampPos = finalUri.find('&', codePos);
      codeParam = ampPos == std::string::npos ? finalUri.substr(codePos)
                                              : finalUri.substr(codePos, ampPos - codePos);
    }
    g_scriptQueue.push_back("globalThis.getAuthorizationCode(\"" + codeParam + "\");");
    shell::Navigate("webkit-extension://" + extensionId + "/popup.html");
    return true;
  }
  return false;
}

bool HandleStylusUsoInstall(const std::string &finalUri) {
  if (finalUri.rfind("https://raw.githubusercontent.com/uso-archive", 0) == 0) {
    std::string extensionId;
    for (const auto &[name, id] : g_extensionMap) {
      if (name.find("stylus") != std::string::npos) {
        extensionId = id;
        break;
      }
    }
    if (extensionId.empty()) {
      std::cout << "[EXTENSIONS]: Extension id not found" << std::endl;
      shell::Navigate(g_webuiUrl);
      return true;
    }
    shell::Navigate("webkit-extension://" + extensionId +
                    "/install-usercss.html?updateUrl=" + finalUri);
    return true;
  }
  return false;
}

// -----------------------------------------------------------------------------
// Web UI bootstrap
// -----------------------------------------------------------------------------
namespace {

ShellWebController *g_webController = nil;

#ifdef DEBUG_LOG
void LogPageStateTick() {
  if (!g_webView) return;
  // Probe the local streaming server from the page context: on macOS this only
  // works because the UI is served from the loopback proxy (see LocalUiProxy.h).
  [g_webView evaluateJavaScript:@"(function(){ if(!window.__probeStarted){ window.__probeStarted=true; fetch('http://127.0.0.1:11470/settings').then(function(r){window.__probe='status:'+r.status;}).catch(function(e){window.__probe='error:'+e;}); } return JSON.stringify({url: location.href, text: (document.body ? document.body.innerText.slice(0, 80) : ''), probe: window.__probe || 'pending', bodyBg: document.body ? getComputedStyle(document.body).backgroundColor : 'n/a', htmlBg: getComputedStyle(document.documentElement).backgroundColor, drawsBg: window.__drawsBg}); })()"
              completionHandler:^(id result, NSError *error) {
                (void)error;
                std::cout << "[WEBVIEW]: page state: "
                          << (result ? NsToUtf8([result description]) : "n/a") << std::endl;
              }];
}
#endif

void MaybeNavigateToWebUi() {
  if (g_didNavigate) return;
  if (g_resolvedWebUiUrl.empty() || !g_extensionsReady.load()) return;
  if (!g_webView) return;

  g_didNavigate = true;
  g_webuiUrl = g_resolvedWebUiUrl;
  std::cout << "[WEBVIEW]: Navigating to " << g_webuiUrl << std::endl;
  shell::Navigate(g_webuiUrl);

#ifdef DEBUG_LOG
  for (int i = 1; i <= 6; i++) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 10 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     LogPageStateTick();
                   });
  }
#endif
}

void AddScripts(WKUserContentController *userContentController) {
  [userContentController
      addUserScript:[[WKUserScript alloc] initWithSource:Script(kShellBootstrapScript)
                                         injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                      forMainFrameOnly:NO]];
  if (SelfTestEnabled()) {
    // The bundled harness implements the transport handshake itself.
    return;
  }
  [userContentController
      addUserScript:[[WKUserScript alloc] initWithSource:Script(kExecShellScript)
                                         injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                      forMainFrameOnly:NO]];
  [userContentController
      addUserScript:[[WKUserScript alloc] initWithSource:Script(kInjectedKeydownScript)
                                         injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                      forMainFrameOnly:NO]];
  SetupWebMods(userContentController);
}

void StartReachabilityThread() {
  std::thread([]() {
    std::cout << "[WEBVIEW]: Checking web ui endpoints..." << std::endl;
    std::string foundUrl = GetFirstReachableUrl();

    std::string resolved = foundUrl;
    if (g_uiProxyEnabled) {
      std::string localBase = StartLocalUiProxy(foundUrl);
      if (!localBase.empty()) {
        resolved = localBase;
      } else {
        std::cout << "[PROXY]: Not used for this endpoint" << std::endl;
      }
    }

    ShellDidResolveWebUiUrl(resolved);
    FetchAndParseWhitelist();
  }).detach();
}

} // namespace

void ShellDidResolveWebUiUrl(const std::string &url) {
  std::string resolved = url;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (resolved.empty()) {
      AppendToCrashLog("[WEBVIEW]: All endpoints unreachable");
      NSAlert *alert = [[NSAlert alloc] init];
      alert.messageText = @"All endpoints are unreachable";
      alert.informativeText = @"Could not reach the Stremio web UI. Check your connection and "
                              @"restart the app.";
      [alert addButtonWithTitle:@"Quit"];
      [alert runModal];
      exit(1);
    }
    g_resolvedWebUiUrl = resolved;
    MaybeNavigateToWebUi();
  });
}

bool InitWebShell() {
  NSWindow *window = ShellMainWindow();
  if (!window) {
    AppendToCrashLog("[WEBVIEW]: Main window missing");
    return false;
  }

  g_config = [[WKWebViewConfiguration alloc] init];
  g_config.websiteDataStore = [WKWebsiteDataStore defaultDataStore];
  g_config.preferences.javaScriptCanOpenWindowsAutomatically = YES;
  if (@available(macOS 10.12, *)) {
    g_config.preferences.elementFullscreenEnabled = YES;
  }

  // Extensions must be attached to the configuration before the web view is
  // created; loading itself is asynchronous and gated by MaybeNavigateToWebUi.
  if (SelfTestEnabled()) {
    g_extensionsReady = true;
  } else if (!g_extensionsStarted) {
    g_extensionsStarted = true;
    SetupExtensions();
    // Watchdog: never let a broken extension block the UI forever.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     if (!g_extensionsReady.load()) {
                       std::cout << "[EXTENSIONS]: setup timed out, continuing without waiting"
                                 << std::endl;
                       FinishExtensionsSetup();
                     }
                   });
  }

  if (SelfTestEnabled()) {
    std::string script =
        "window.__selftestMediaPath = " + json(g_selfTestMediaPath).dump() + ";";
    [g_config.userContentController
        addUserScript:[[WKUserScript alloc] initWithSource:Utf8ToNs(script)
                                           injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                        forMainFrameOnly:YES]];
  }

  AddScripts(g_config.userContentController);

  ScriptMessageProxy *proxy = [[ScriptMessageProxy alloc] initWithTarget:nil];
  g_webController = [[ShellWebController alloc] init];
  proxy.target = g_webController;
  [g_config.userContentController addScriptMessageHandler:proxy name:@"stremioShell"];
#ifdef DEBUG_LOG
  [g_config.userContentController addScriptMessageHandler:proxy name:@"stremioConsole"];
  [g_config.userContentController addUserScript:[[WKUserScript alloc] initWithSource:Script(kConsoleForwardScript)
                                                                     injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                                  forMainFrameOnly:YES]];
#endif

  NSView *contentView = [window contentView];
  g_webView = [[WKWebView alloc] initWithFrame:contentView.bounds configuration:g_config];
  g_webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  g_webView.navigationDelegate = g_webController;
  g_webView.UIDelegate = g_webController;
  g_webView.customUserAgent = [NSString stringWithFormat:@"StremioShell/%s", APP_VERSION];
  g_webView.allowsBackForwardNavigationGestures = NO;
  g_webView.allowsMagnification = g_allowZoom;

  // The web UI paints transparent regions over the native video, exactly like
  // the WebView2 background color (0,0,0,0) trick on Windows.
  @try {
    [g_webView setValue:@NO forKey:@"drawsBackground"];
  } @catch (NSException *exception) {
    AppendToCrashLog("[WEBVIEW]: drawsBackground not available: " +
                     NsToUtf8(exception.reason ?: @""));
  }
  if (@available(macOS 12.0, *)) {
    g_webView.underPageBackgroundColor = [NSColor clearColor];
  }
  if (@available(macOS 13.3, *)) {
#ifdef DEBUG_LOG
    g_webView.inspectable = YES;
#else
    g_webView.inspectable = NO;
#endif
  }

  [contentView addSubview:g_webView positioned:NSWindowAbove relativeTo:nil];

  if (SelfTestEnabled()) {
    g_resolvedWebUiUrl = "file://" + g_resourcesDir + "/selftest.html";
    MaybeNavigateToWebUi();
  } else {
    StartReachabilityThread();
  }

  // The splash was created before the web view; keep it on top.
  ShellBringSplashToFront();
  return true;
}

// -----------------------------------------------------------------------------
// Retry loop (parity with WaitAndRefreshIfNeeded in webview.cpp)
// -----------------------------------------------------------------------------
void WaitAndRefreshIfNeeded() {
  std::thread([]() {
    const int maxAttempts = 10;
    const int initialWaitTime = 5;
    const int maxWaitTime = 60;

    std::cout << "[WEBVIEW]: Web Page could not be reached, retrying..." << std::endl;

    for (int attempt = 0; attempt < maxAttempts; ++attempt) {
      int waitTime = (int)(initialWaitTime * std::pow(1.25, attempt));
      if (waitTime > maxWaitTime) waitTime = maxWaitTime;

      std::this_thread::sleep_for(std::chrono::seconds(waitTime));

      if (g_isAppReady) {
        std::cout << "[WEBVIEW]: Web Page ready!" << std::endl;
        g_waitStarted.store(false);
        return;
      }
      std::cout << "[WEBVIEW]: Refreshing attempt " << (attempt + 1) << std::endl;
      shell::Reload(false);
    }

    if (!g_isAppReady) {
      AppendToCrashLog("[WEBVIEW]: Could not load after attempts");
      dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Web page could not be loaded after multiple attempts.";
        alert.informativeText = @"Make sure the Web UI is reachable.";
        [alert addButtonWithTitle:@"Quit"];
        [alert runModal];
        exit(1);
      });
    }
  }).detach();
}
