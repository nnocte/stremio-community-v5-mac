#ifndef TRAY_H
#define TRAY_H

// Status bar item (Windows: src/tray/tray.cpp).
void CreateTrayIcon();
void RemoveTrayIcon();
void UpdateTray();

// True when the status bar item exists (used by the self test).
bool TrayCreated();

#endif // TRAY_H
