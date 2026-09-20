#ifndef POWER_H
#define POWER_H

// Keeps the display awake while video is playing (the official shell does the
// same through screensaver-toggle; macOS uses an IOPM assertion).
void SetDisplaySleepBlocked(bool blocked);

#endif // POWER_H
