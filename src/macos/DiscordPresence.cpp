#include "DiscordPresence.h"

#include <chrono>
#include <cstring>
#include <ctime>
#include <iostream>

#include "DiscordRpc.h"
#include "Log.h"
#include "Shell.h"

namespace {

int SafeStoi(const std::string &value, int fallback = 0) {
  try {
    return std::stoi(value);
  } catch (...) {
    return fallback;
  }
}

void Discord_Ready(const DiscordUser *user) {
  std::cout << "[DISCORD]: Connected to Discord user: "
            << (user && user->username ? user->username : "unknown") << std::endl;
}

void Discord_Disconnected(int errorCode, const char *message) {
  std::cout << "[DISCORD]: Disconnected (" << errorCode << "): "
            << (message ? message : "") << std::endl;
}

void Discord_Error(int errorCode, const char *message) {
  std::string text = "[DISCORD]: Error (" + std::to_string(errorCode) + "): " +
                     (message ? message : "");
  std::cout << text << std::endl;
  AppendToCrashLog(text);
}

// Payload layout matches src/utils/discord.cpp:
//  0 watching | 1 type | 2 title | 3 season | 4 episode | 5 episode name
//  6 episode image | 7 show image | 8 elapsed | 9 duration | 10 paused
//  11 imdb link | 12 stremio link
void SetDiscordWatchingPresence(const std::vector<std::string> &args) {
  DiscordRichPresence presence{};
  presence.type = DISCORD_ACTIVITY_TYPE_WATCHING;
  presence.details = args[2].c_str();
  presence.largeImageKey = args[7].c_str();
  presence.largeImageText = args[2].c_str();

  bool isPaused = args.size() > 10 && !args[10].empty() && args[10] == "yes";

  // The DiscordRichPresence struct only borrows pointers, so composed strings
  // must outlive Discord_UpdatePresence().
  static thread_local std::string stateStorage;

  if (isPaused) {
    presence.state = "Paused";
  } else {
    std::time_t currentTime = std::chrono::system_clock::to_time_t(std::chrono::system_clock::now());
    int elapsedSeconds = SafeStoi(args[8]);
    int durationSeconds = SafeStoi(args[9]);

    presence.startTimestamp = (int64_t)currentTime - elapsedSeconds;
    presence.endTimestamp = (int64_t)currentTime + (durationSeconds - elapsedSeconds);

    if (args[1] == "series") {
      stateStorage = args[5] + " (S" + args[3] + "-E" + args[4] + ")";
      presence.state = stateStorage.c_str();

      if (args.size() > 6 && !args[6].empty()) {
        presence.smallImageKey = args[6].c_str();
        presence.smallImageText = args[5].c_str();
      }
    } else {
      presence.state = "Enjoying a Movie";
    }
  }

  if (args.size() > 11 && !args[11].empty()) {
    presence.button1Label = "More Details";
    presence.button1Url = args[11].c_str();
  }
  if (args.size() > 12 && !args[12].empty()) {
    presence.button2Label = "Watch on Stremio";
    presence.button2Url = args[12].c_str();
  }

  Discord_UpdatePresence(&presence);
}

void SetDiscordMetaDetailPresence(const std::vector<std::string> &args) {
  DiscordRichPresence presence{};
  presence.type = DISCORD_ACTIVITY_TYPE_WATCHING;
  presence.details = args[2].c_str();
  presence.largeImageKey = args[3].c_str();
  presence.largeImageText = args[2].c_str();
  presence.state = args[1] == "movie" ? "Exploring a Movie" : "Exploring a Series";
  Discord_UpdatePresence(&presence);
}

void SetDiscordDiscoverPresence(const std::string &details, const std::string &state) {
  DiscordRichPresence presence{};
  presence.type = DISCORD_ACTIVITY_TYPE_WATCHING;
  presence.state = state.c_str();
  presence.details = details.c_str();
  presence.largeImageKey =
      "https://raw.githubusercontent.com/Stremio/stremio-web/refs/heads/development/images/icon.png";
  presence.largeImageText = "Stremio";
  Discord_UpdatePresence(&presence);
}

} // namespace

void InitializeDiscord() {
  DiscordEventHandlers handlers{};
  std::memset(&handlers, 0, sizeof(handlers));
  handlers.ready = Discord_Ready;
  handlers.disconnected = Discord_Disconnected;
  handlers.errored = Discord_Error;

  // Upstream's Discord application id; the presence only shows for this app.
  Discord_Initialize("1361448446862692492", &handlers, 1, nullptr);
}

void SetDiscordPresenceFromArgs(const std::vector<std::string> &args) {
  if (!g_isRpcOn || args.empty()) {
    return;
  }

  const std::string &embedType = args[0];
  if (embedType == "watching" && args.size() >= 12) {
    SetDiscordWatchingPresence(args);
  } else if (embedType == "meta-detail" && args.size() >= 4) {
    SetDiscordMetaDetailPresence(args);
  } else if (embedType == "board") {
    SetDiscordDiscoverPresence("Resuming Favorites", "On Board");
  } else if (embedType == "discover") {
    SetDiscordDiscoverPresence("Finding New Gems", "In Discover");
  } else if (embedType == "library") {
    SetDiscordDiscoverPresence("Revisiting Old Favorites", "In Library");
  } else if (embedType == "calendar") {
    SetDiscordDiscoverPresence("Planning My Next Binge", "On Calendar");
  } else if (embedType == "addons") {
    SetDiscordDiscoverPresence("Exploring Add-ons", "In Add-ons");
  } else if (embedType == "settings") {
    SetDiscordDiscoverPresence("Tuning Preferences", "In Settings");
  } else if (embedType == "search") {
    SetDiscordDiscoverPresence("Searching for Shows & Movies", "In Search");
  } else if (embedType == "clear") {
    Discord_ClearPresence();
  }
}
