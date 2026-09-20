#ifndef MPV_H
#define MPV_H

#include <string>
#include <vector>

// Ported from src/mpv/player.cpp. On macOS the video output is always the
// libmpv render API ("vo=libmpv"); the GL context lives in VideoView.mm.
bool InitMPV();
void CleanupMPV();
void HandleMpvEvents();

void HandleMpvCommand(const std::vector<std::string> &args);
void HandleMpvSetProp(const std::vector<std::string> &args);
void HandleMpvObserveProp(const std::vector<std::string> &args);
void pauseMPV(bool allowed);

#endif // MPV_H
