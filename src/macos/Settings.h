#ifndef SETTINGS_H
#define SETTINGS_H

#include <string>

struct WindowPlacement {
  int left = 0;
  int top = 0;
  int right = 0;
  int bottom = 0;
  int showCmd = 1; // 1 = normal, 3 = zoomed (Win32 SW_SHOWMAXIMIZED parity)
  bool valid = false;
};

void LoadSettings();
void SaveSettings();

void SaveWindowPlacement(const WindowPlacement &placement);
bool LoadWindowPlacement(WindowPlacement &placement);

std::string GetSettingsIniPath();

#endif // SETTINGS_H
