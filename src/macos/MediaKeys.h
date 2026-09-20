#ifndef MEDIAKEYS_H
#define MEDIAKEYS_H

#include <string>

// Media key / Now Playing integration (the Windows build registers
// VK_MEDIA_PLAY_PAUSE; macOS routes media keys through MPRemoteCommandCenter).
void InitMediaKeys();
void UpdateNowPlaying(const std::string &title, double durationSeconds, double positionSeconds,
                      bool paused);
void ClearNowPlaying();

#endif // MEDIAKEYS_H
