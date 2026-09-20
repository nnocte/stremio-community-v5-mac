#ifndef DISCORD_RPC_H
#define DISCORD_RPC_H

// Minimal macOS implementation of the discord-rpc C API surface used by
// src/utils/discord.cpp. Talks the documented IPC protocol over the
// $TMPDIR/discord-ipc-* unix sockets, so the Windows presence code compiles
// unchanged.

#include <cstdint>

#ifdef __cplusplus
extern "C" {
#endif

// Activity types (Discord API).
#define DISCORD_ACTIVITY_TYPE_PLAYING 0
#define DISCORD_ACTIVITY_TYPE_STREAMING 1
#define DISCORD_ACTIVITY_TYPE_LISTENING 2
#define DISCORD_ACTIVITY_TYPE_WATCHING 3

typedef struct DiscordUser {
  const char *userId;
  const char *username;
  const char *discriminator;
  const char *avatar;
} DiscordUser;

typedef struct DiscordRichPresence {
  int type;
  const char *state;
  const char *details;
  int64_t startTimestamp; // seconds since epoch, 0 when unset
  int64_t endTimestamp;
  const char *largeImageKey;
  const char *largeImageText;
  const char *smallImageKey;
  const char *smallImageText;
  const char *partyId;
  int partySize;
  int partyMax;
  const char *matchSecret;
  const char *joinSecret;
  const char *spectateSecret;
  int8_t instance;
  const char *button1Label;
  const char *button1Url;
  const char *button2Label;
  const char *button2Url;
} DiscordRichPresence;

typedef struct DiscordEventHandlers {
  void (*ready)(const DiscordUser *user);
  void (*disconnected)(int errorCode, const char *message);
  void (*errored)(int errorCode, const char *message);
  void (*joinGame)(const char *joinSecret);
  void (*spectateGame)(const char *spectateSecret);
  void (*joinRequest)(const DiscordUser *request);
} DiscordEventHandlers;

void Discord_Initialize(const char *applicationId, DiscordEventHandlers *handlers,
                        int autoRegister, const char *optionalSteamId);
void Discord_Shutdown(void);
void Discord_RunCallbacks(void);
void Discord_UpdatePresence(const DiscordRichPresence *presence);
void Discord_ClearPresence(void);
void Discord_Respond(const char *userId, int reply);
void Discord_UpdateHandlers(DiscordEventHandlers *handlers);

#ifdef __cplusplus
}
#endif

#endif // DISCORD_RPC_H
