#include "Log.h"
#include "Shell.h"

#include <cstdio>
#include <csignal>
#include <cstring>
#include <ctime>
#include <execinfo.h>
#include <fcntl.h>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <sstream>
#include <unistd.h>

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#include <dispatch/dispatch.h>

namespace {

std::mutex g_logMutex;
bool g_handlersInstalled = false;

std::string DailyLogPath() {
  std::time_t t = std::time(nullptr);
  std::tm localTime{};
  localtime_r(&t, &localTime);

  std::ostringstream filename;
  filename << "/errors-" << localTime.tm_mday << "." << (localTime.tm_mon + 1) << "."
           << (localTime.tm_year + 1900) << ".txt";
  return g_configDir + filename.str();
}

// Async-signal-safe log path: no allocation.
void CrashHandler(int sig) {
  char header[160];
  int len = std::snprintf(header, sizeof(header), "\n[CRASH] signal %d (%s)\n", sig,
                          strsignal(sig));
  if (len > 0) {
    int fd = open(DailyLogPath().c_str(), O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
      ssize_t ignored = write(fd, header, (size_t)len);
      (void)ignored;
      void *frames[64];
      int count = backtrace(frames, 64);
      backtrace_symbols_fd(frames, count, fd);
      close(fd);
    }
  }
  signal(sig, SIG_DFL);
  raise(sig);
}

} // namespace

void AppendToCrashLog(const std::string &message) {
  {
    std::lock_guard<std::mutex> lock(g_logMutex);
    std::time_t t = std::time(nullptr);
    std::tm localTime{};
    localtime_r(&t, &localTime);

    std::ofstream logFile(DailyLogPath(), std::ios::app);
    if (logFile.is_open()) {
      logFile << "[" << std::put_time(&localTime, "%H:%M:%S") << "] " << message << std::endl;
    }
  }
  std::cerr << "[LOG] " << message << "\n";
}

// SIGTERM/SIGINT (kill, Ctrl+C, logout) must run the normal shutdown path so
// the streaming server and the single instance socket are cleaned up.
void InstallTerminationHandler() {
  static int signalPipe[2] = {-1, -1};
  // ARC would release a local dispatch source when this function returns.
  [[maybe_unused]] static dispatch_source_t signalSource = nil;
  if (pipe(signalPipe) != 0) return;

  dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, signalPipe[0], 0,
                                                    dispatch_get_main_queue());
  signalSource = source;
  dispatch_source_set_event_handler(source, ^{
    char buffer[16];
    ssize_t ignored = read(signalPipe[0], buffer, sizeof(buffer));
    (void)ignored;
    std::cout << "Received termination signal, shutting down" << std::endl;
    [NSApp terminate:nil];
  });
  dispatch_resume(source);

  auto handler = [](int sig) {
    const char message[] = "[SIGNAL] caught termination signal\n";
    ssize_t ignored = write(STDERR_FILENO, message, sizeof(message) - 1);
    char byte = (char)sig;
    ignored = write(signalPipe[1], &byte, 1);
    (void)ignored;
  };
  signal(SIGTERM, handler);
  signal(SIGINT, handler);
}

void InstallCrashHandlers() {
  if (g_handlersInstalled) return;
  g_handlersInstalled = true;

  static const int signals[] = {SIGSEGV, SIGABRT, SIGILL, SIGFPE, SIGBUS, SIGTRAP};
  for (int sig : signals) {
    signal(sig, CrashHandler);
  }
  signal(SIGPIPE, SIG_IGN);

  NSSetUncaughtExceptionHandler([](NSException *exception) {
    std::string reason = exception.reason ? [exception.reason UTF8String] : "";
    std::string name = exception.name ? [exception.name UTF8String] : "";
    AppendToCrashLog("[CRASH] Uncaught Objective-C exception " + name + ": " + reason);
  });
}
