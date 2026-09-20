#ifndef MACUTIL_H
#define MACUTIL_H

// Small Objective-C++ helpers. Include only from .mm files.

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#include <string>

std::string NsToUtf8(NSString *str);
NSString *Utf8ToNs(const std::string &str);

// Loads a PNG from the bundle resources (nil when missing).
NSImage *LoadResourceImage(NSString *name);

// Fetches an http(s) URL synchronously (background threads only).
// method nil => GET. Returns nil on error.
NSData *DownloadUrlSync(NSString *url, NSTimeInterval timeout, NSInteger *statusCode,
                        NSString *method);

#endif // MACUTIL_H
