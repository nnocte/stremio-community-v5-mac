#ifndef CAPTURE_H
#define CAPTURE_H

#include <string>

// Captures the main window to a PNG (diagnostic for --capture-window=).
// Capturing the app's own window does not require Screen Recording permission.
bool CaptureMainWindowToPng(const std::string &path);

#endif // CAPTURE_H
