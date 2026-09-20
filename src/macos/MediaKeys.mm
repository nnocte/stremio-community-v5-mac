#include "MediaKeys.h"

#import <MediaPlayer/MediaPlayer.h>

#include <iostream>

#include "Log.h"
#include "MacUtil.h"
#include "MPV.h"
#include "Shell.h"

namespace {
bool g_mediaKeysInitialized = false;
bool g_playbackActive = false;

void SendPause(bool paused) {
  HandleMpvSetProp({"pause", paused ? "yes" : "no"});
}
} // namespace

void InitMediaKeys() {
  if (g_mediaKeysInitialized) return;
  g_mediaKeysInitialized = true;

  MPRemoteCommandCenter *center = [MPRemoteCommandCenter sharedCommandCenter];

  [center.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(
                                       MPRemoteCommandEvent *event) {
    (void)event;
    SendPause(false);
    return MPRemoteCommandHandlerStatusSuccess;
  }];

  [center.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(
                                        MPRemoteCommandEvent *event) {
    (void)event;
    SendPause(true);
    return MPRemoteCommandHandlerStatusSuccess;
  }];

  [center.togglePlayPauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(
                                                  MPRemoteCommandEvent *event) {
    (void)event;
    HandleMpvCommand({"cycle", "pause"});
    return MPRemoteCommandHandlerStatusSuccess;
  }];

  [center.nextTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(
                                            MPRemoteCommandEvent *event) {
    (void)event;
    HandleMpvCommand({"playlist-next"});
    return MPRemoteCommandHandlerStatusSuccess;
  }];

  [center.previousTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(
                                                MPRemoteCommandEvent *event) {
    (void)event;
    HandleMpvCommand({"playlist-prev"});
    return MPRemoteCommandHandlerStatusSuccess;
  }];

  std::cout << "[MEDIAKEYS]: remote command center ready" << std::endl;
}

void UpdateNowPlaying(const std::string &title, double durationSeconds, double positionSeconds,
                      bool paused) {
  if (!g_mediaKeysInitialized) return;

  g_playbackActive = durationSeconds > 0;

  MPRemoteCommandCenter *center = [MPRemoteCommandCenter sharedCommandCenter];
  center.playCommand.enabled = g_playbackActive;
  center.pauseCommand.enabled = g_playbackActive;
  center.togglePlayPauseCommand.enabled = g_playbackActive;
  center.nextTrackCommand.enabled = g_playbackActive;
  center.previousTrackCommand.enabled = g_playbackActive;

  if (!g_playbackActive) {
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = nil;
    return;
  }

  NSString *nowPlayingTitle = title.empty() ? Utf8ToNs(APP_NAME) : Utf8ToNs(title);
  [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = @{
    MPMediaItemPropertyTitle : nowPlayingTitle,
    MPMediaItemPropertyArtist : Utf8ToNs(APP_NAME),
    MPMediaItemPropertyPlaybackDuration : @(durationSeconds),
    MPNowPlayingInfoPropertyElapsedPlaybackTime : @(positionSeconds),
    MPNowPlayingInfoPropertyPlaybackRate : @(paused ? 0.0 : 1.0),
  };
}

void ClearNowPlaying() {
  if (!g_mediaKeysInitialized) return;
  g_playbackActive = false;
  [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = nil;
}
