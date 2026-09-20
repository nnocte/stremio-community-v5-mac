#import "Tray.h"

#import <Cocoa/Cocoa.h>

#include <iostream>

#include "AppWindow.h"
#include "Log.h"
#include "MacUtil.h"
#include "MPV.h"
#include "Settings.h"
#include "Shell.h"
#include "WebShell.h"

// Same item order and labels as the Windows tray menu.
enum TrayAction {
  kShowWindow = 1001,
  kAlwaysOnTop = 1002,
  kCloseOnExit = 1003,
  kUseDarkTheme = 1004,
  kPauseMinimized = 1005,
  kPauseFocusLost = 1006,
  kPictureInPicture = 1007,
  kQuit = 1008,
};

static NSStatusItem *g_statusItem = nil;
static NSMenu *g_trayMenu = nil;
static id g_trayTarget = nil;
static bool g_trayCreated = false;

@interface ShellTrayTarget : NSObject
- (void)trayAction:(NSMenuItem *)sender;
- (void)statusItemClicked:(id)sender;
@end

@implementation ShellTrayTarget

- (void)trayAction:(NSMenuItem *)sender {
  switch (sender.tag) {
    case kShowWindow:
      g_showWindow = !g_showWindow;
      if (g_showWindow) {
        shell::ShowMainWindow();
      } else {
        shell::HideMainWindow();
      }
      break;
    case kAlwaysOnTop:
      shell::SetAlwaysOnTop(!g_alwaysOnTop);
      break;
    case kPictureInPicture:
      shell::SetPip(!g_isPipMode);
      break;
    case kPauseMinimized:
      g_pauseOnMinimize = !g_pauseOnMinimize;
      SaveSettings();
      break;
    case kPauseFocusLost:
      g_pauseOnLostFocus = !g_pauseOnLostFocus;
      SaveSettings();
      break;
    case kCloseOnExit:
      g_closeOnExit = !g_closeOnExit;
      SaveSettings();
      break;
    case kUseDarkTheme:
      g_useDarkTheme = !g_useDarkTheme;
      SaveSettings();
      shell::UpdateTheme();
      break;
    case kQuit: {
      if (g_mpv) mpv_command_string(g_mpv, "quit");
      shell::Quit();
      break;
    }
    default:
      break;
  }
  UpdateTray();
}

- (void)statusItemClicked:(id) __unused sender {
  NSEvent *event = NSApp.currentEvent;
  if (event.clickCount == 2) {
    shell::ShowMainWindow();
    return;
  }
  if (!g_trayMenu || !g_statusItem.button) return;
  [g_trayMenu popUpMenuPositioningItem:nil
                            atLocation:NSMakePoint(0, g_statusItem.button.bounds.size.height)
                                inView:g_statusItem.button];
}

@end

static NSMenuItem *AddItem(NSMenu *menu, NSString *title, NSInteger tag) {
  NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                               action:@selector(trayAction:)
                                        keyEquivalent:@""];
  item.tag = tag;
  item.target = g_trayTarget;
  [menu addItem:item];
  return item;
}

void CreateTrayIcon() {
  if (g_statusItem) return;

  g_trayTarget = [[ShellTrayTarget alloc] init];

  g_statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];

  NSImage *icon = LoadResourceImage(@"stremio.png");
  if (icon) {
    [icon setSize:NSMakeSize(18, 18)];
    [icon setTemplate:YES]; // adapt to light/dark menu bar
    g_statusItem.button.image = icon;
  } else {
    g_statusItem.button.title = @"S";
  }
  g_statusItem.button.toolTip = @"Stremio";
  g_statusItem.button.target = g_trayTarget;
  g_statusItem.button.action = @selector(statusItemClicked:);
  [g_statusItem.button sendActionOn:NSEventMaskLeftMouseUp];

  g_trayMenu = [[NSMenu alloc] initWithTitle:@"Stremio"];
  AddItem(g_trayMenu, @"Show Window", kShowWindow);
  AddItem(g_trayMenu, @"Always on Top", kAlwaysOnTop);
  AddItem(g_trayMenu, @"Picture in Picture", kPictureInPicture);
  AddItem(g_trayMenu, @"Pause Minimized", kPauseMinimized);
  AddItem(g_trayMenu, @"Pause Unfocused", kPauseFocusLost);
  AddItem(g_trayMenu, @"Close on Exit", kCloseOnExit);
  AddItem(g_trayMenu, @"Use Dark Theme", kUseDarkTheme);
  [g_trayMenu addItem:[NSMenuItem separatorItem]];
  AddItem(g_trayMenu, @"Quit", kQuit);

  g_trayCreated = true;
  UpdateTray();
}

bool TrayCreated() {
  return g_trayCreated;
}

void RemoveTrayIcon() {
  if (!g_statusItem) return;
  [[NSStatusBar systemStatusBar] removeStatusItem:g_statusItem];
  g_statusItem = nil;
  g_trayMenu = nil;
}

void UpdateTray() {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!g_trayMenu) return;
    for (NSMenuItem *item in g_trayMenu.itemArray) {
      switch (item.tag) {
        case kShowWindow:
          item.state = g_showWindow ? NSControlStateValueOn : NSControlStateValueOff;
          break;
        case kAlwaysOnTop:
          item.state = g_alwaysOnTop ? NSControlStateValueOn : NSControlStateValueOff;
          break;
        case kPictureInPicture:
          item.state = g_isPipMode ? NSControlStateValueOn : NSControlStateValueOff;
          break;
        case kPauseMinimized:
          item.state = g_pauseOnMinimize ? NSControlStateValueOn : NSControlStateValueOff;
          break;
        case kPauseFocusLost:
          item.state = g_pauseOnLostFocus ? NSControlStateValueOn : NSControlStateValueOff;
          break;
        case kCloseOnExit:
          item.state = g_closeOnExit ? NSControlStateValueOn : NSControlStateValueOff;
          break;
        case kUseDarkTheme:
          item.state = g_useDarkTheme ? NSControlStateValueOn : NSControlStateValueOff;
          break;
        default:
          break;
      }
    }
  });
}
