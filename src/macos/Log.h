#ifndef LOG_H
#define LOG_H

#include <string>

// Appends a line to <configDir>/errors-<day>.<month>.<year>.txt (same file
// naming as the Windows build) and mirrors it to stderr.
void AppendToCrashLog(const std::string &message);

// Installs signal + Objective-C exception handlers that append a crash report
// before the process dies.
void InstallCrashHandlers();

// Routes SIGTERM/SIGINT through NSApplication terminate so shutdown is clean.
void InstallTerminationHandler();

// Saves settings, shuts down mpv/node/discord and releases the single instance
// lock. Safe to call more than once (atexit + explicit shutdown).
void Cleanup();

#endif // LOG_H
