#ifndef DISCORD_PRESENCE_H
#define DISCORD_PRESENCE_H

#include <string>
#include <vector>

// macOS equivalents of src/utils/discord.cpp. The presence payloads and event
// names are kept identical to the Windows build.
void InitializeDiscord();
void SetDiscordPresenceFromArgs(const std::vector<std::string> &args);

#endif // DISCORD_PRESENCE_H
