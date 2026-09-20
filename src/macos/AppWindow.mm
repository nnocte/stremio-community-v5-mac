#import "AppWindow.h"

#import <Cocoa/Cocoa.h>

#include <iostream>
#include <vector>

#include "Bridge.h"
#include "Log.h"
#include "MPV.h"
#include "MacUtil.h"
#include "Settings.h"
#include "Shell.h"
#include "Splash.h"
#include "Tray.h"
#include "VideoView.h"
#include "WebShell.h"

static NSWindow *g_window = nil;
static id g_windowDelegate = nil;
static id g_appDelegate = nil;

namespace {
const NSWindowStyleMask kNormalStyle = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                       NSWindowStyleMaskMiniaturizable |
                                       NSWindowStyleMaskResizable;
NSWindowStyleMask g_prePipStyle = kNormalStyle;

// Synchronous appliers; the shell:: wrappers marshal them to the main thread.
void ApplyAlwaysOnTop(bool on) {
  g_alwaysOnTop = on;
  g_window.level = on ? NSFloatingWindowLevel : NSNormalWindowLevel;
  ::UpdateTray();
}

void ApplyTheme() {
  NSAppearanceName name = g_useDarkTheme ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua;
  NSAppearance *appearance = [NSAppearance appearanceNamed:name];
  NSApp.appearance = appearance;
  g_window.appearance = appearance;
}

void ApplyPip(bool enable) {
  if (enable == g_isPipMode) return;
  g_isPipMode = enable;

  if (enable) {
    g_prePipStyle = g_window.styleMask;
    g_window.styleMask = NSWindowStyleMaskBorderless;
    g_alwaysOnTop = true;
    g_window.level = NSFloatingWindowLevel;
  } else {
    g_window.styleMask = g_prePipStyle;
    g_alwaysOnTop = false;
    g_window.level = NSNormalWindowLevel;
  }

  nlohmann::json j;
  SendToJS(enable ? "showPictureInPicture" : "hidePictureInPicture", j);
  ::UpdateTray();
}
} // namespace

// -----------------------------------------------------------------------------
// Main window
// -----------------------------------------------------------------------------
void ShellCreateMainWindow() {
  NSRect frame = NSMakeRect(0, 0, 1200, 900);

  WindowPlacement placement;
  bool hasPlacement = LoadWindowPlacement(placement) && placement.valid;
  if (hasPlacement && placement.right > placement.left && placement.bottom > placement.top) {
    frame = NSMakeRect(placement.left, placement.top, placement.right - placement.left,
                       placement.bottom - placement.top);
  }

  g_window = [[NSWindow alloc] initWithContentRect:frame
                                         styleMask:kNormalStyle
                                           backing:NSBackingStoreBuffered
                                             defer:NO];
  g_window.title = @APP_TITLE;
  g_window.minSize = NSMakeSize(640, 480);
  g_window.backgroundColor = [NSColor blackColor];
  g_window.releasedWhenClosed = NO;
  g_window.acceptsMouseMovedEvents = YES;

  if (g_windowDelegate) {
    g_window.delegate = g_windowDelegate;
  }

  NSView *contentView = g_window.contentView;

  MPVVideoView *videoView = [[MPVVideoView alloc] initWithFrame:contentView.bounds];
  videoView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [contentView addSubview:videoView];

  // Keep the window on a visible screen if the saved frame went stale.
  bool onScreen = false;
  for (NSScreen *screen in [NSScreen screens]) {
    if (NSIntersectsRect(frame, screen.visibleFrame)) {
      onScreen = true;
      break;
    }
  }
  if (!onScreen) {
    [g_window center];
  } else if (hasPlacement && placement.showCmd == 3) {
    [g_window zoom:nil];
  }

  [g_window makeKeyAndOrderFront:nil];
}

NSWindow *ShellMainWindow(void) {
  return g_window;
}

// -----------------------------------------------------------------------------
// Menu actions
// -----------------------------------------------------------------------------
@interface ShellMenuTarget : NSObject
- (void)reload:(id)sender;
- (void)forceReload:(id)sender;
- (void)zoomIn:(id)sender;
- (void)zoomOut:(id)sender;
- (void)zoomReset:(id)sender;
- (void)toggleFullScreen:(id)sender;
@end

@implementation ShellMenuTarget
- (void)reload:(id)sender {
  (void)sender;
  RefreshWebFromNative();
}
- (void)forceReload:(id)sender {
  (void)sender;
  shell::Reload(true);
}
- (void)zoomIn:(id)sender {
  (void)sender;
  WebShellSetPageZoom(WebShellPageZoom() + 0.1);
}
- (void)zoomOut:(id)sender {
  (void)sender;
  WebShellSetPageZoom(WebShellPageZoom() - 0.1);
}
- (void)zoomReset:(id)sender {
  (void)sender;
  WebShellSetPageZoom(1.0);
}
- (void)toggleFullScreen:(id)sender {
  (void)sender;
  shell::ToggleFullScreen(!g_isFullscreen);
}
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
  if (menuItem.action == @selector(zoomIn:) || menuItem.action == @selector(zoomOut:) ||
      menuItem.action == @selector(zoomReset:)) {
    return g_allowZoom;
  }
  return YES;
}
@end

static NSMenu *BuildMainMenu(ShellMenuTarget *target) {
  NSMenu *mainMenu = [[NSMenu alloc] init];

  // Application menu
  NSMenuItem *appItem = [[NSMenuItem alloc] init];
  [mainMenu addItem:appItem];
  NSMenu *appMenu = [[NSMenu alloc] init];
  [appMenu addItemWithTitle:@"About Stremio"
                     action:@selector(orderFrontStandardAboutPanel:)
              keyEquivalent:@""];
  [appMenu addItem:[NSMenuItem separatorItem]];
  [appMenu addItemWithTitle:@"Hide Stremio" action:@selector(hide:) keyEquivalent:@"h"];
  NSMenuItem *hideOthers = [appMenu addItemWithTitle:@"Hide Others"
                                              action:@selector(hideOtherApplications:)
                                       keyEquivalent:@"h"];
  hideOthers.keyEquivalentModifierMask = NSEventModifierFlagOption | NSEventModifierFlagCommand;
  [appMenu addItemWithTitle:@"Show All"
                     action:@selector(unhideAllApplications:)
              keyEquivalent:@""];
  [appMenu addItem:[NSMenuItem separatorItem]];
  [appMenu addItemWithTitle:@"Quit Stremio" action:@selector(terminate:) keyEquivalent:@"q"];
  appItem.submenu = appMenu;

  // Edit menu (standard selectors go to the first responder, i.e. the web view)
  NSMenuItem *editItem = [[NSMenuItem alloc] init];
  [mainMenu addItem:editItem];
  NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
  [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
  NSMenuItem *redo = [editMenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"z"];
  redo.keyEquivalentModifierMask = NSEventModifierFlagShift | NSEventModifierFlagCommand;
  [editMenu addItem:[NSMenuItem separatorItem]];
  [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
  [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
  [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
  NSMenuItem *pasteMatch = [editMenu addItemWithTitle:@"Paste and Match Style"
                                               action:@selector(pasteAsPlainText:)
                                        keyEquivalent:@"v"];
  pasteMatch.keyEquivalentModifierMask = NSEventModifierFlagOption | NSEventModifierFlagShift |
                                         NSEventModifierFlagCommand;
  [editMenu addItemWithTitle:@"Delete" action:@selector(delete:) keyEquivalent:@""];
  [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
  editItem.submenu = editMenu;

  // View menu
  NSMenuItem *viewItem = [[NSMenuItem alloc] init];
  [mainMenu addItem:viewItem];
  NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
  [viewMenu addItemWithTitle:@"Reload" action:@selector(reload:) keyEquivalent:@"r"].target = target;
  NSMenuItem *forceReload = [viewMenu addItemWithTitle:@"Force Reload"
                                                action:@selector(forceReload:)
                                         keyEquivalent:@"r"];
  forceReload.keyEquivalentModifierMask = NSEventModifierFlagShift | NSEventModifierFlagCommand;
  forceReload.target = target;
  [viewMenu addItem:[NSMenuItem separatorItem]];

  NSMenuItem *zoomIn = [viewMenu addItemWithTitle:@"Zoom In"
                                           action:@selector(zoomIn:)
                                    keyEquivalent:@"+"];
  zoomIn.target = target;
  NSMenuItem *zoomOut = [viewMenu addItemWithTitle:@"Zoom Out"
                                            action:@selector(zoomOut:)
                                     keyEquivalent:@"-"];
  zoomOut.target = target;
  NSMenuItem *zoomReset = [viewMenu addItemWithTitle:@"Actual Size"
                                              action:@selector(zoomReset:)
                                       keyEquivalent:@"0"];
  zoomReset.target = target;
  [viewMenu addItem:[NSMenuItem separatorItem]];

  NSMenuItem *fullScreen = [viewMenu addItemWithTitle:@"Toggle Full Screen"
                                               action:@selector(toggleFullScreen:)
                                        keyEquivalent:@"f"];
  fullScreen.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagCommand;
  fullScreen.target = target;
  viewItem.submenu = viewMenu;

  // Window menu
  NSMenuItem *windowItem = [[NSMenuItem alloc] init];
  [mainMenu addItem:windowItem];
  NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
  [windowMenu addItemWithTitle:@"Minimize"
                        action:@selector(performMiniaturize:)
                 keyEquivalent:@"m"];
  [windowMenu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
  [windowMenu addItem:[NSMenuItem separatorItem]];
  [windowMenu addItemWithTitle:@"Bring All to Front"
                        action:@selector(arrangeInFront:)
                 keyEquivalent:@""];
  windowItem.submenu = windowMenu;
  NSApp.windowsMenu = windowMenu;

  return mainMenu;
}

// -----------------------------------------------------------------------------
// Application delegate
// -----------------------------------------------------------------------------
@interface ShellAppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation ShellAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *) __unused notification {
  ShellMenuTarget *target = [[ShellMenuTarget alloc] init];
  NSApp.mainMenu = BuildMainMenu(target);
  [NSApp activateIgnoringOtherApps:YES];
  [g_window makeKeyAndOrderFront:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *) __unused sender {
  return NO; // tray application: closing the window keeps playback alive
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *) __unused sender
                    hasVisibleWindows:(BOOL)hasVisibleWindows {
  if (!hasVisibleWindows) {
    shell::ShowMainWindow();
  }
  return YES;
}

- (void)application:(NSApplication *) __unused application openURLs:(NSArray<NSURL *> *)urls {
  for (NSURL *url in urls) {
    std::string arg = url.isFileURL ? NsToUtf8(url.path) : NsToUtf8(url.absoluteString);
    std::cout << "[PROTOCOL]: LaunchServices URL " << arg << std::endl;
    if (!g_isAppReady) {
      g_launchProtocol = arg;
    } else {
      HandleLaunchProtocol(arg);
    }
  }
  shell::ShowMainWindow();
}

- (void)application:(NSApplication *) __unused application openFiles:(NSArray<NSString *> *)filenames {
  for (NSString *path in filenames) {
    std::string arg = NsToUtf8(path);
    std::cout << "[PROTOCOL]: LaunchServices file " << arg << std::endl;
    if (!g_isAppReady) {
      g_launchProtocol = arg;
    } else {
      HandleLaunchProtocol(arg);
    }
  }
  shell::ShowMainWindow();
}

- (void)applicationDidResignActive:(NSNotification *) __unused notification {
  pauseMPV(g_pauseOnLostFocus);
}

- (void)applicationWillTerminate:(NSNotification *) __unused notification {
  // Cleanup() is invoked from main()'s atexit handler as well; it is idempotent.
}

@end

// -----------------------------------------------------------------------------
// Window delegate
// -----------------------------------------------------------------------------
@interface ShellWindowDelegate : NSObject <NSWindowDelegate>
@end

@implementation ShellWindowDelegate

- (BOOL)windowShouldClose:(NSWindow *)sender {
  WindowPlacement placement;
  placement.left = (int)sender.frame.origin.x;
  placement.top = (int)sender.frame.origin.y;
  placement.right = (int)(sender.frame.origin.x + sender.frame.size.width);
  placement.bottom = (int)(sender.frame.origin.y + sender.frame.size.height);
  placement.showCmd = sender.isZoomed ? 3 : 1;
  placement.valid = true;
  SaveWindowPlacement(placement);

  if (g_closeOnExit) {
    [NSApp terminate:nil];
    return NO;
  }

  [sender orderOut:nil];
  pauseMPV(g_pauseOnMinimize);
  g_showWindow = false;
  ::UpdateTray();
  return NO;
}

- (void)windowDidMiniaturize:(NSNotification *) __unused notification {
  pauseMPV(g_pauseOnMinimize);
}

- (void)windowDidEnterFullScreen:(NSNotification *) __unused notification {
  g_isFullscreen = true;
}

- (void)windowDidExitFullScreen:(NSNotification *) __unused notification {
  g_isFullscreen = false;
}

@end

// -----------------------------------------------------------------------------
// shell:: platform interface
// -----------------------------------------------------------------------------
namespace shell {

void ShowMainWindow() {
  dispatch_async(dispatch_get_main_queue(), ^{
    g_showWindow = true;
    [g_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    ::UpdateTray();
  });
}

void HideMainWindow() {
  dispatch_async(dispatch_get_main_queue(), ^{
    g_showWindow = false;
    [g_window orderOut:nil];
    ::UpdateTray();
  });
}

void SetAlwaysOnTop(bool on) {
  dispatch_async(dispatch_get_main_queue(), ^{
    ApplyAlwaysOnTop(on);
  });
}

void ToggleFullScreen(bool enable) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (enable == g_isFullscreen) return;
    g_isFullscreen = enable;
    [g_window toggleFullScreen:nil];
  });
}

void SetPip(bool enable) {
  dispatch_async(dispatch_get_main_queue(), ^{
    ApplyPip(enable);
  });
}

void OpenExternal(const std::string &uri) {
  if (uri.empty()) return;
  std::string target = uri;
  dispatch_async(dispatch_get_main_queue(), ^{
    NSURL *url = [NSURL URLWithString:Utf8ToNs(target)];
    if (!url) {
      AppendToCrashLog("[SHELL]: Invalid external url " + target);
      return;
    }
    [[NSWorkspace sharedWorkspace] openURL:url];
  });
}

void StartDrag() {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!g_window) return;
    NSEvent *event = NSApp.currentEvent;
    if (!event || (event.type != NSEventTypeLeftMouseDown &&
                   event.type != NSEventTypeLeftMouseDragged)) {
      NSPoint location = [NSEvent mouseLocation];
      event = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                 location:location
                            modifierFlags:0
                                timestamp:[[NSProcessInfo processInfo] systemUptime]
                             windowNumber:g_window.windowNumber
                                  context:nil
                              eventNumber:0
                               clickCount:1
                                 pressure:1.0];
    }
    [g_window performWindowDragWithEvent:event];
  });
}

void UpdateTheme() {
  dispatch_async(dispatch_get_main_queue(), ^{
    ApplyTheme();
  });
}

void Quit() {
  dispatch_async(dispatch_get_main_queue(), ^{
    [NSApp terminate:nil];
  });
}

void PostAppReady() {
  // Called by Bridge (app-ready) and by the node server before/after readiness.
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!g_isAppReady.load()) return;

    for (const auto &message : g_outboundMessages) {
      std::string type = message.contains("type") && message["type"].is_string()
                             ? message["type"].get<std::string>()
                             : std::string();
      SendToJS(type, message);
    }
    g_outboundMessages.clear();

    if (!g_launchProtocol.empty()) {
      std::string arg = g_launchProtocol;
      g_launchProtocol.clear();
      HandleLaunchProtocol(arg);
    }
  });
}

} // namespace shell

// -----------------------------------------------------------------------------
// Self test support (called on the main thread by SelfTest.mm)
// -----------------------------------------------------------------------------
std::string ShellWindowModeSelfCheck() {
  nlohmann::json checks;

  // Picture in Picture: borderless + floating, then restore.
  NSWindowStyleMask styleBefore = g_window.styleMask;
  NSWindowLevel levelBefore = g_window.level;
  bool pipBefore = g_isPipMode;
  ApplyPip(!pipBefore);
  bool pipApplied = g_window.styleMask == NSWindowStyleMaskBorderless &&
                    g_window.level == NSFloatingWindowLevel && g_isPipMode == !pipBefore;
  ApplyPip(pipBefore);
  bool pipRestored = g_window.styleMask == styleBefore && g_window.level == levelBefore;
  checks["pip-toggle"] = pipApplied && pipRestored;

  // Always on top.
  bool topBefore = g_alwaysOnTop;
  ApplyAlwaysOnTop(true);
  bool topApplied = g_window.level == NSFloatingWindowLevel;
  ApplyAlwaysOnTop(false);
  bool topCleared = g_window.level == NSNormalWindowLevel;
  ApplyAlwaysOnTop(topBefore);
  checks["always-on-top"] = topApplied && topCleared;

  // Theme switching affects both the app and the window appearance.
  bool themeBefore = g_useDarkTheme;
  g_useDarkTheme = true;
  ApplyTheme();
  bool darkApplied = [NSApp.effectiveAppearance.name isEqualToString:NSAppearanceNameDarkAqua];
  g_useDarkTheme = false;
  ApplyTheme();
  bool lightApplied = [NSApp.effectiveAppearance.name isEqualToString:NSAppearanceNameAqua];
  g_useDarkTheme = themeBefore;
  ApplyTheme();
  checks["dark-theme"] = darkApplied && lightApplied;

  // Status bar item.
  checks["tray-icon"] = TrayCreated();

  // Zoom setting (WebShellSetPageZoom is a no-op unless AllowZoom is on).
  bool zoomBefore = g_allowZoom;
  g_allowZoom = true;
  WebShellApplyPageZoom(1.25);
  bool zoomApplied = WebShellPageZoom() > 1.2 && WebShellPageZoom() < 1.3;
  WebShellApplyPageZoom(1.0);
  g_allowZoom = zoomBefore;
  checks["page-zoom"] = zoomApplied;

  // Splash must be gone once the web UI reported app-ready.
  checks["splash-hidden"] = !SplashVisible();

  return checks.dump();
}

// -----------------------------------------------------------------------------
// Init (main.mm)
// -----------------------------------------------------------------------------
void ShellInitAppDelegates() {
  g_appDelegate = [[ShellAppDelegate alloc] init];
  NSApp.delegate = g_appDelegate;

  g_windowDelegate = [[ShellWindowDelegate alloc] init];
}
