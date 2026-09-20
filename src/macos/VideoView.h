#import <Cocoa/Cocoa.h>

// Video surface backed by the libmpv render API (OpenGL). Placed behind the
// transparent WKWebView inside the main window, the same layering the Windows
// build achieves with wid=main window + transparent WebView2.
@interface MPVVideoView : NSView

- (void)shutdownRenderer;

@end
