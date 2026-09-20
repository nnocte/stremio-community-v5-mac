#include "Settings.h"

#include <algorithm>
#include <iostream>
#include <sstream>
#include <vector>

#include "IniFile.h"
#include "Log.h"
#include "Shell.h"
#include "Strings.h"

// Same file name and layout as the Windows build:
//   <portable_config>/stremio-settings.ini
std::string GetSettingsIniPath() {
  if (g_configDir.empty()) return "stremio-settings.ini";
  return g_configDir + "/stremio-settings.ini";
}

namespace {

std::vector<std::string> SplitCsv(const std::string &value) {
  std::vector<std::string> out;
  std::stringstream ss(value);
  std::string token;
  while (std::getline(ss, token, ',')) {
    size_t a = token.find_first_not_of(" \t\r\n");
    if (a == std::string::npos) continue;
    size_t b = token.find_last_not_of(" \t\r\n");
    token = ToLowerStr(token.substr(a, b - a + 1));
    if (!token.empty()) out.push_back(token);
  }
  return out;
}

// Ported from the Windows build: effective = defaults UNION user extras.
// The file is rewritten whenever a default is missing so upgrades add new
// defaults without dropping user additions.
void LoadMergedAllowlist(IniFile &ini, const std::string &key, const std::string &defaults,
                         std::unordered_set<std::string> &out) {
  std::vector<std::string> defs = SplitCsv(defaults);
  std::vector<std::string> users = SplitCsv(ini.Get("Security", key));
  std::vector<std::string> effective = defs;

  for (const auto &u : users) {
    if (std::find(effective.begin(), effective.end(), u) == effective.end()) {
      effective.push_back(u);
    }
  }

  bool rewrite = false;
  for (const auto &d : defs) {
    if (std::find(users.begin(), users.end(), d) == users.end()) {
      rewrite = true;
      break;
    }
  }
  if (rewrite) {
    std::string joined;
    for (size_t i = 0; i < effective.size(); ++i) {
      if (i) joined += ",";
      joined += effective[i];
    }
    ini.Set("Security", key, joined);
    ini.Save();
  }

  out.clear();
  for (const auto &e : effective) out.insert(e);
}

} // namespace

void LoadSettings() {
  IniFile ini(GetSettingsIniPath());
  ini.Load();

  g_closeOnExit = ini.GetInt("General", "CloseOnExit", 0) == 1;
  g_useDarkTheme = ini.GetInt("General", "UseDarkTheme", 1) == 1;
  g_thumbFastHeight = ini.GetInt("General", "ThumbFastHeight", 0);
  g_allowZoom = ini.GetInt("General", "AllowZoom", 0) == 1;
  g_pauseOnMinimize = ini.GetInt("General", "PauseOnMinimize", 1) == 1;
  g_pauseOnLostFocus = ini.GetInt("General", "PauseOnLostFocus", 0) == 1;
  g_isRpcOn = ini.GetInt("General", "DiscordRPC", 1) == 1;

  std::string videoOutput = ini.Get("MPV", "VideoOutput", "gpu-next");
  // The render API requires vo=libmpv; remember the requested value for logs
  // but never hand it to mpv as the actual video output.
  std::cout << "[SETTINGS]: configured VideoOutput=" << videoOutput
            << " (macOS forces libmpv render API)" << std::endl;
  g_initialVO = "libmpv";
  g_currentVolume = ini.GetInt("MPV", "InitialVolume", 50);

  static const char *kDefCmds = "loadfile,sub-add,keypress,stop,script-message-to,cycle";
  static const char *kDefProps =
      "pause,time-pos,speed,mute,volume,aid,sid,no-sub-ass,vo,osc,"
      "input-default-bindings,input-vo-keyboard,sub-scale,sub-pos,sub-delay,"
      "sub-color,sub-back-color,sub-border-color,hwdec,hwdec-codecs,"
      "subs-with-matching-audio,subs-match-os-language,subs-fallback,subs-fallback-forced";

  LoadMergedAllowlist(ini, "MpvCommandAllowlist", kDefCmds, g_mpvCommandAllowlist);
  LoadMergedAllowlist(ini, "MpvSetPropAllowlist", kDefProps, g_mpvSetPropAllowlist);
}

void SaveSettings() {
  IniFile ini(GetSettingsIniPath());
  ini.Load();

  ini.Set("General", "CloseOnExit", g_closeOnExit ? "1" : "0");
  ini.Set("General", "UseDarkTheme", g_useDarkTheme ? "1" : "0");
  ini.Set("General", "PauseOnMinimize", g_pauseOnMinimize ? "1" : "0");
  ini.Set("General", "PauseOnLostFocus", g_pauseOnLostFocus ? "1" : "0");
  ini.Set("General", "AllowZoom", g_allowZoom ? "1" : "0");
  ini.Set("General", "DiscordRPC", g_isRpcOn ? "1" : "0");
  ini.Set("MPV", "InitialVolume", std::to_string(g_currentVolume));

  if (!ini.Save()) {
    AppendToCrashLog("[SETTINGS]: Failed to save " + ini.Path());
  }
}

void SaveWindowPlacement(const WindowPlacement &placement) {
  IniFile ini(GetSettingsIniPath());
  ini.Load();

  ini.Set("Window", "ShowCmd", std::to_string(placement.showCmd));
  ini.Set("Window", "Left", std::to_string(placement.left));
  ini.Set("Window", "Top", std::to_string(placement.top));
  ini.Set("Window", "Right", std::to_string(placement.right));
  ini.Set("Window", "Bottom", std::to_string(placement.bottom));
  ini.Save();
}

bool LoadWindowPlacement(WindowPlacement &placement) {
  IniFile ini(GetSettingsIniPath());
  ini.Load();

  int left = ini.GetInt("Window", "Left", -1);
  int top = ini.GetInt("Window", "Top", -1);
  int right = ini.GetInt("Window", "Right", -1);
  int bottom = ini.GetInt("Window", "Bottom", -1);
  if (left == -1 || top == -1 || right == -1 || bottom == -1) {
    placement.valid = false;
    return false;
  }

  placement.left = left;
  placement.top = top;
  placement.right = right;
  placement.bottom = bottom;
  placement.showCmd = ini.GetInt("Window", "ShowCmd", 1);
  placement.valid = true;
  return true;
}
