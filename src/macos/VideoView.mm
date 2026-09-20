#import "VideoView.h"

#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>

#include <dlfcn.h>
#include <math.h>

#include <iostream>

#include "Log.h"
#include "Shell.h"

#include "mpv/client.h"
#include "mpv/render.h"
#include "mpv/render_gl.h"

namespace {
void *GLGetProcAddress(void * /*ctx*/, const char *name) {
  // OpenGL.framework exports the full GL symbol set, so RTLD_DEFAULT is enough.
  return dlsym(RTLD_DEFAULT, name);
}
} // namespace

@interface MPVVideoLayer : CAOpenGLLayer
- (void)shutdownRenderer;
- (BOOL)rendererReady;
@end

@implementation MPVVideoLayer {
  CGLContextObj _cglContext;
  mpv_render_context *_renderContext;
  BOOL _rendererShutdown;
}

- (CGLPixelFormatObj)copyCGLPixelFormatForDisplayMask:(uint32_t)mask {
  const CGLPixelFormatAttribute attribs[] = {
      kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
      kCGLPFADoubleBuffer,
      kCGLPFAColorSize,     (CGLPixelFormatAttribute)24,
      kCGLPFAAlphaSize,     (CGLPixelFormatAttribute)8,
      kCGLPFADepthSize,     (CGLPixelFormatAttribute)0,
      kCGLPFADisplayMask,   (CGLPixelFormatAttribute)mask,
      (CGLPixelFormatAttribute)0};

  CGLPixelFormatObj pixelFormat = nullptr;
  GLint numFormats = 0;
  if (CGLChoosePixelFormat(attribs, &pixelFormat, &numFormats) != kCGLNoError) {
    AppendToCrashLog("[VIDEO]: CGLChoosePixelFormat failed");
    return nullptr;
  }
  return pixelFormat;
}

- (CGLContextObj)copyCGLContextForPixelFormat:(CGLPixelFormatObj)pixelFormat {
  CGLContextObj ctx = nullptr;
  if (CGLCreateContext(pixelFormat, nullptr, &ctx) != kCGLNoError) {
    AppendToCrashLog("[VIDEO]: CGLCreateContext failed");
    return nullptr;
  }
  _cglContext = ctx;
  CGLSetCurrentContext(ctx);

  if (!g_mpv) {
    AppendToCrashLog("[VIDEO]: mpv core not created yet");
    return ctx;
  }

  static const char *apiType = MPV_RENDER_API_TYPE_OPENGL;
  mpv_opengl_init_params glParams{};
  glParams.get_proc_address = GLGetProcAddress;
  glParams.get_proc_address_ctx = nullptr;

  int advancedControl = 0;
  mpv_render_param params[] = {
      {MPV_RENDER_PARAM_API_TYPE, (void *)apiType},
      {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, (void *)&glParams},
      {MPV_RENDER_PARAM_ADVANCED_CONTROL, (void *)&advancedControl},
      {MPV_RENDER_PARAM_INVALID, nullptr}};

  int err = mpv_render_context_create(&_renderContext, g_mpv, params);
  if (err < 0) {
    AppendToCrashLog(std::string("[VIDEO]: mpv_render_context_create failed: ") +
                     mpv_error_string(err));
    _renderContext = nullptr;
    return ctx;
  }

  mpv_render_context_set_update_callback(
      _renderContext,
      [](void *callbackCtx) {
        MPVVideoLayer *layer = (__bridge MPVVideoLayer *)callbackCtx;
        dispatch_async(dispatch_get_main_queue(), ^{
          [layer renderTick];
        });
      },
      (__bridge void *)self);

  std::cout << "[VIDEO]: mpv render context created" << std::endl;
  return ctx;
}

- (void)renderTick {
  if (!_renderContext || _rendererShutdown) return;
  CGLSetCurrentContext(_cglContext);
  uint64_t flags = mpv_render_context_update(_renderContext);
  if (flags & MPV_RENDER_UPDATE_FRAME) {
#ifdef DEBUG_LOG
    static std::atomic<int> updates{0};
    if (updates.fetch_add(1) < 3) std::cout << "[VIDEO]: update frame" << std::endl;
#endif
    [self setNeedsDisplay];
  }
}

- (BOOL)canDrawInCGLContext:(CGLContextObj) __unused ctx
                pixelFormat:(CGLPixelFormatObj) __unused pixelFormat
               forLayerTime:(CFTimeInterval) __unused timeInterval
                displayTime:(const CVTimeStamp *) __unused displayTime {
  return _renderContext != nullptr && !_rendererShutdown && self.bounds.size.width > 0 &&
         self.bounds.size.height > 0;
}

- (void)drawInCGLContext:(CGLContextObj)ctx
             pixelFormat:(CGLPixelFormatObj) __unused pixelFormat
            forLayerTime:(CFTimeInterval) __unused timeInterval
             displayTime:(const CVTimeStamp *) __unused displayTime {
  if (!_renderContext || _rendererShutdown) return;

  CGLLockContext(ctx);
  CGLSetCurrentContext(ctx);

  const CGFloat scale = self.contentsScale > 0 ? self.contentsScale : 1.0;
  int width = (int)fmax(1.0, self.bounds.size.width * scale);
  int height = (int)fmax(1.0, self.bounds.size.height * scale);

  glViewport(0, 0, width, height);
  glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
  glClear(GL_COLOR_BUFFER_BIT);

  mpv_opengl_fbo mpvFbo{};
  mpvFbo.fbo = 0;
  mpvFbo.w = width;
  mpvFbo.h = height;
  mpvFbo.internal_format = 0;

  int flipY = 1;
  mpv_render_param params[] = {
      {MPV_RENDER_PARAM_OPENGL_FBO, (void *)&mpvFbo},
      {MPV_RENDER_PARAM_FLIP_Y, (void *)&flipY},
      {MPV_RENDER_PARAM_INVALID, nullptr}};

  mpv_render_context_render(_renderContext, params);
#ifdef DEBUG_LOG
  static std::atomic<int> draws{0};
  if (draws.fetch_add(1) < 3) {
    std::cout << "[VIDEO]: drew frame " << width << "x" << height << std::endl;
  }
#endif
  CGLFlushDrawable(ctx);
  CGLUnlockContext(ctx);
}

- (void)shutdownRenderer {
  if (_rendererShutdown) return;
  _rendererShutdown = YES;

  if (_renderContext) {
    mpv_render_context_set_update_callback(_renderContext, nullptr, nullptr);
    if (_cglContext) {
      CGLLockContext(_cglContext);
      CGLSetCurrentContext(_cglContext);
    }
    mpv_render_context_free(_renderContext);
    if (_cglContext) CGLUnlockContext(_cglContext);
    _renderContext = nullptr;
  }
}

- (BOOL)rendererReady {
  return _renderContext != nullptr;
}

- (void)dealloc {
  [self shutdownRenderer];
}

@end

static __weak MPVVideoView *g_videoView = nil;

@implementation MPVVideoView {
  MPVVideoLayer *_videoLayer;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  self = [super initWithFrame:frameRect];
  if (self) {
    _videoLayer = [[MPVVideoLayer alloc] init];
    _videoLayer.frame = self.bounds;
    _videoLayer.contentsScale = 1.0;
    _videoLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    _videoLayer.contentsGravity = kCAGravityResize;

    self.layer = _videoLayer;
    self.wantsLayer = YES;
    g_videoView = self;
  }
  return self;
}

- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  _videoLayer.frame = self.bounds;
  [_videoLayer setNeedsDisplay];
}

- (void)viewDidChangeBackingProperties {
  [super viewDidChangeBackingProperties];
  _videoLayer.contentsScale = self.window ? self.window.backingScaleFactor : 1.0;
  _videoLayer.frame = self.bounds;
  [_videoLayer setNeedsDisplay];
}

- (void)shutdownRenderer {
  [_videoLayer shutdownRenderer];
}

- (BOOL)rendererReady {
  return [_videoLayer rendererReady];
}

- (BOOL)acceptsFirstResponder {
  return NO;
}

@end

void ShutdownRenderer() {
  MPVVideoView *view = g_videoView;
  if (view) [view shutdownRenderer];
}

bool RendererReady() {
  MPVVideoView *view = g_videoView;
  if (!view) return false;
  return [view rendererReady];
}
