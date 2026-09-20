#import "Splash.h"

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

#include <iostream>

#include "AppWindow.h"
#include "Log.h"
#include "MacUtil.h"
#include "Shell.h"

// Pulsing logo overlay; same visual behaviour as the Windows splash window
// (opacity 0.3..1.0, ~1.1x per-tick speed) but driven by a 60 Hz timer.
static const CGFloat kMinOpacity = 0.3;
static const CGFloat kMaxOpacity = 1.0;
// Windows: 0.01 * 1.1 per 4 ms tick == ~2.75 units/second.
static const CGFloat kOpacityPerSecond = 0.01 * 1.1 * 250.0;

@interface SplashView : NSView
@property(nonatomic, strong) NSImage *logo;
@property(nonatomic, assign) CGFloat opacityLevel;
@property(nonatomic, assign) CGFloat direction;
@property(nonatomic, strong) NSTimer *pulseTimer;
@property(nonatomic, assign) CFTimeInterval lastTick;
- (void)startPulsing;
- (void)stopPulsing;
@end

@implementation SplashView

- (instancetype)initWithFrame:(NSRect)frameRect {
  self = [super initWithFrame:frameRect];
  if (self) {
    _opacityLevel = kMaxOpacity;
    _direction = -1.0;
    _lastTick = CACurrentMediaTime();
    self.wantsLayer = YES;
    CGColorRef background = CGColorCreateGenericRGB(12.0 / 255.0, 11.0 / 255.0, 17.0 / 255.0, 1.0);
    self.layer.backgroundColor = background;
    CGColorRelease(background);
  }
  return self;
}

- (BOOL)isOpaque {
  return YES;
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (self.window) {
    [self startPulsing];
  } else {
    [self stopPulsing];
  }
}

- (void)startPulsing {
  if (self.pulseTimer) return;
  self.lastTick = CACurrentMediaTime();
  self.pulseTimer = [NSTimer scheduledTimerWithTimeInterval:(1.0 / 60.0)
                                                     target:self
                                                   selector:@selector(tick:)
                                                   userInfo:nil
                                                    repeats:YES];
  self.pulseTimer.tolerance = 0.005;
}

- (void)stopPulsing {
  [self.pulseTimer invalidate];
  self.pulseTimer = nil;
}

- (void)tick:(NSTimer *) __unused timer {
  CFTimeInterval now = CACurrentMediaTime();
  CGFloat delta = (CGFloat)(now - self.lastTick);
  self.lastTick = now;
  if (delta > 0.25) delta = 0.25; // window was occluded; avoid jumps

  self.opacityLevel += self.direction * kOpacityPerSecond * delta;
  if (self.opacityLevel <= kMinOpacity) {
    self.opacityLevel = kMinOpacity;
    self.direction = 1.0;
  } else if (self.opacityLevel >= kMaxOpacity) {
    self.opacityLevel = kMaxOpacity;
    self.direction = -1.0;
  }
  [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
  [[NSColor colorWithCalibratedRed:12.0 / 255.0 green:11.0 / 255.0 blue:17.0 / 255.0 alpha:1.0]
      setFill];
  NSRectFill(dirtyRect);

  if (!self.logo) return;

  NSSize logoSize = self.logo.size;
  NSRect target = NSMakeRect((NSWidth(self.bounds) - logoSize.width) / 2.0,
                             (NSHeight(self.bounds) - logoSize.height) / 2.0,
                             logoSize.width, logoSize.height);
  [self.logo drawInRect:target
               fromRect:NSZeroRect
              operation:NSCompositingOperationSourceOver
               fraction:self.opacityLevel
         respectFlipped:YES
                  hints:nil];
}

@end

static SplashView *g_splashView = nil;

void CreateSplashScreen() {
  NSWindow *window = ShellMainWindow();
  if (!window) {
    AppendToCrashLog("[SPLASH]: Main window missing");
    return;
  }

  NSView *contentView = [window contentView];
  g_splashView = [[SplashView alloc] initWithFrame:contentView.bounds];
  g_splashView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

  NSImage *logo = LoadResourceImage(@"stremio.png");
  if (!logo) {
    std::cerr << "[SPLASH]: Could not load stremio.png" << std::endl;
  }
  g_splashView.logo = logo;

  [contentView addSubview:g_splashView positioned:NSWindowAbove relativeTo:nil];
  [g_splashView startPulsing];
}

void HideSplash() {
  SplashView *view = g_splashView;
  if (!view) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    [view stopPulsing];
    [view removeFromSuperview];
    g_splashView = nil;
  });
}

bool SplashVisible() {
  return g_splashView != nil;
}

void ShellBringSplashToFront() {
  SplashView *view = g_splashView;
  if (!view || !view.superview) return;
  [view.superview addSubview:view positioned:NSWindowAbove relativeTo:nil];
}
