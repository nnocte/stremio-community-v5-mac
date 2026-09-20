#import "Capture.h"

#import <Cocoa/Cocoa.h>

#include <dlfcn.h>

#include <iostream>

#include "AppWindow.h"
#include "Log.h"
#include "MacUtil.h"

bool CaptureMainWindowToPng(const std::string &path) {
  NSWindow *window = ShellMainWindow();
  if (!window) {
    AppendToCrashLog("[CAPTURE]: no main window");
    return false;
  }

  CGWindowID windowId = (CGWindowID)window.windowNumber;

  // ScreenCaptureKit is the supported replacement but always requires Screen
  // Recording permission. This diagnostic only needs the app's own window, so
  // resolve the legacy symbol at runtime (still shipped by the OS) and fall
  // back gracefully when it is gone.
  using CreateImageFn = CGImageRef (*)(CGRect, CGWindowListOption, CGWindowID,
                                       CGWindowImageOption);
  static CreateImageFn createImage =
      (CreateImageFn)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
  if (!createImage) {
    AppendToCrashLog("[CAPTURE]: CGWindowListCreateImage unavailable");
    return false;
  }

  CGImageRef image = createImage(CGRectNull, kCGWindowListOptionIncludingWindow, windowId,
                                 kCGWindowImageBoundsIgnoreFraming);
  if (!image) {
    AppendToCrashLog("[CAPTURE]: window capture failed");
    return false;
  }

  NSBitmapImageRep *representation = [[NSBitmapImageRep alloc] initWithCGImage:image];
  CGImageRelease(image);

  NSData *png = [representation representationUsingType:NSBitmapImageFileTypePNG
                                             properties:@{}];
  if (!png) {
    AppendToCrashLog("[CAPTURE]: PNG encoding failed");
    return false;
  }

  bool ok = [png writeToFile:Utf8ToNs(path) atomically:YES];
  std::cout << "[CAPTURE]: " << (ok ? "wrote " : "failed ") << path << std::endl;
  return ok;
}
