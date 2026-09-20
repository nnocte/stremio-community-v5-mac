#ifndef APPWINDOW_H
#define APPWINDOW_H

#import <Cocoa/Cocoa.h>

#include <string>

// The main shell window (Windows: the Win32 window created in main.cpp).
NSWindow *ShellMainWindow(void);
void ShellCreateMainWindow(void);

// Installs the NSApplication + NSWindow delegates; call before creating the window.
void ShellInitAppDelegates(void);

// Exercises window modes (PiP, always-on-top, theme, tray, zoom) and returns a
// JSON object with the results. Must be called on the main thread.
std::string ShellWindowModeSelfCheck(void);

#endif // APPWINDOW_H
