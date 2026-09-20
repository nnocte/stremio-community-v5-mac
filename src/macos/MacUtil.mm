#import "MacUtil.h"

#import <AppKit/AppKit.h>

std::string NsToUtf8(NSString *str) {
  if (!str) return {};
  const char *utf8 = [str UTF8String];
  return utf8 ? std::string(utf8) : std::string();
}

NSString *Utf8ToNs(const std::string &str) {
  return [[NSString alloc] initWithBytes:str.data()
                                  length:str.size()
                                encoding:NSUTF8StringEncoding];
}

NSImage *LoadResourceImage(NSString *name) {
  NSString *path = [[NSBundle mainBundle] pathForResource:name ofType:nil];
  if (!path) {
    // Dev builds: resources live next to the binary.
    NSString *exeDir = [[[NSBundle mainBundle] executablePath] stringByDeletingLastPathComponent];
    path = [exeDir stringByAppendingPathComponent:name];
  }
  if (!path) return nil;
  return [[NSImage alloc] initWithContentsOfFile:path];
}

NSData *DownloadUrlSync(NSString *url, NSTimeInterval timeout, NSInteger *statusCode,
                        NSString *method) {
  NSURL *nsurl = [NSURL URLWithString:url];
  if (!nsurl) return nil;

  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:nsurl];
  request.timeoutInterval = timeout;
  if (method) request.HTTPMethod = method;
  request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
  [request setValue:@"StremioShell/" APP_VERSION forHTTPHeaderField:@"User-Agent"];

  __block NSData *result = nil;
  __block NSInteger status = 0;
  dispatch_semaphore_t sema = dispatch_semaphore_create(0);

  NSURLSessionDataTask *task = [[NSURLSession sharedSession]
      dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
          if (!error && data) {
            result = data;
            if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
              status = ((NSHTTPURLResponse *)response).statusCode;
            } else {
              status = 200;
            }
          }
          dispatch_semaphore_signal(sema);
        }];
  [task resume];
  dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout + 2.0) * NSEC_PER_SEC)));
  if (statusCode) *statusCode = status;
  return result;
}
