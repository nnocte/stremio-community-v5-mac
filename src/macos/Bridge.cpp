#include "Bridge.h"

#include <atomic>
#include <chrono>
#include <iostream>

#include "DiscordPresence.h"
#include "Log.h"
#include "MPV.h"
#include "SelfTest.h"
#include "Shell.h"
#include "Splash.h"
#include "Strings.h"
#include "Updater.h"
#include "WebShell.h"

// -----------------------------------------------------------------------------
// Native -> JS
// -----------------------------------------------------------------------------
void SendToJS(const std::string &eventName, const nlohmann::json &eventData) {
  static std::atomic<int> nextId{1};
  nlohmann::json msg;
  msg["type"] = 1;
  msg["object"] = "transport";
  msg["id"] = nextId++;
  msg["args"] = {eventName, eventData};

  std::string payload = msg.dump();
#ifdef DEBUG_LOG
  std::cout << "[Native->JS] " << payload << "\n";
#endif
  shell::SendToWeb(payload);
}

// -----------------------------------------------------------------------------
// Event handling (ported from src/ui/mainwindow.cpp)
// -----------------------------------------------------------------------------
void HandleEvent(const std::string &ev, std::vector<std::string> &args) {
  if (ev == "mpv-command") {
    // Allow list check
    std::string cmdName = args.empty() ? "" : ToLowerStr(args[0]);
    if (!g_mpvCommandAllowlist.count(cmdName)) {
      std::string full;
      for (size_t i = 0; i < args.size(); ++i) {
        if (i) full += " ";
        full += args[i];
      }
      AppendToCrashLog("[SECURITY]: BLOCKED mpv-command => " + full);
      nlohmann::json j;
      j["type"] = "MpvCommandBlocked";
      j["command"] = cmdName;
      j["full"] = full;
      SendToJS("MpvCommandBlocked", j);
      return;
    }

    if (!args.empty() && args[0] == "loadfile" && args.size() > 1) {
      if (args[1].rfind("http://", 0) != 0 && args[1].rfind("https://", 0) != 0) {
        args[1] = decodeURIComponent(args[1]);
      }
      HandleMpvSetProp({"vo", g_initialVO});
      HandleMpvSetProp({"volume", std::to_string(g_currentVolume)});
      g_initialSet = true;
    }
    HandleMpvCommand(args);
  } else if (ev == "mpv-set-prop") {
    // Allow list check
    std::string prop = args.empty() ? "" : ToLowerStr(args[0]);
    if (!g_mpvSetPropAllowlist.count(prop)) {
      std::string val = args.size() > 1 ? args[1] : "";
      AppendToCrashLog("[SECURITY]: BLOCKED mpv-set-prop => " + prop + " = " + val);
      nlohmann::json j;
      j["type"] = "MpvSetPropBlocked";
      j["prop"] = prop;
      j["value"] = val;
      SendToJS("MpvSetPropBlocked", j);
      return;
    }
    // macOS renders through the libmpv render API; the web UI asks for
    // gpu-next/gpu after loadfile, which would tear down the render context.
    if (prop == "vo") {
      args = {"vo", g_initialVO};
    }
    HandleMpvSetProp(args);
  } else if (ev == "mpv-observe-prop") {
    HandleMpvObserveProp(args);
  } else if (ev == "app-ready") {
    std::cout << "[BRIDGE]: Web UI reported app-ready" << std::endl;
    g_isAppReady = true;
    HideSplash();
    shell::PostAppReady();
  } else if (ev == "update-requested") {
    RunInstallerAndExit();
  } else if (ev == "seek-hover") {
    if (g_thumbFastHeight == 0) return;
    if (g_ignoreHover) {
      auto now = std::chrono::steady_clock::now();
      if (now < g_ignoreUntil) {
        return;
      }
      g_ignoreHover = false;
    }

    if (args.size() < 3) {
      std::cerr << "[BRIDGE]: seek-hover requires at least 3 arguments.\n";
      return;
    }

    int yCoord = 0;
    try {
      yCoord = std::stoi(args[2]);
    } catch (const std::exception &e) {
      std::cerr << "[BRIDGE]: Error converting y coordinate: " << e.what() << "\n";
      return;
    }

    int adjustedY = yCoord - g_thumbFastHeight;
    HandleMpvCommand({"script-message-to", "thumbfast", "thumb", args[0], args[1],
                      std::to_string(adjustedY)});
  } else if (ev == "seek-leave") {
    if (g_thumbFastHeight == 0) return;
    g_ignoreHover = true;
    g_ignoreUntil = std::chrono::steady_clock::now() + IGNORE_DURATION;
    HandleMpvCommand({"script-message-to", "thumbfast", "clear"});
  } else if (ev == "start-drag") {
    shell::StartDrag();
  } else if (ev == "refresh") {
    shell::Reload(args.size() > 0 && args[0] == "all");
  } else if (ev == "app-error") {
    if (!args.empty() && args[0] == "shellComm") {
      if (!g_isAppReady && !g_waitStarted.exchange(true)) {
        WaitAndRefreshIfNeeded();
      }
    }
  } else if (ev == "open-external") {
    if (!args.empty()) shell::OpenExternal(args[0]);
  } else if (ev == "navigate") {
    if (args.empty()) return;
    if (args[0] == "home") {
      shell::Navigate(g_webuiUrl);
    } else {
      shell::Navigate(args[0]);
    }
  } else if (ev == "activity") {
    SetDiscordPresenceFromArgs(args);
  } else if (ev == "quit") {
    shell::Quit();
  } else if (ev.rfind("selftest-", 0) == 0 && SelfTestEnabled()) {
    SelfTestHandleEvent(ev, args);
  } else {
    std::cout << "[BRIDGE]: Unknown event=" << ev << "\n";
  }
}

// -----------------------------------------------------------------------------
// JS -> native
// -----------------------------------------------------------------------------
void HandleInboundJSON(const std::string &msg) {
  try {
#ifdef DEBUG_LOG
    std::cout << "[JS -> NATIVE]: " << msg << std::endl;
#endif

    auto j = nlohmann::json::parse(msg);
    int type = 0;
    if (j.contains("type") && j["type"].is_number()) {
      type = j["type"].get<int>();
    }

    if (type == 3) {
      // 3 = Init event (Qt transport handshake)
      nlohmann::json root;
      root["id"] = 0;
      nlohmann::json transportObj;

      json extData = json::object();
      if (!g_extensionMap.empty()) {
        for (auto &[name, id] : g_extensionMap) {
          extData[name] = id;
        }
      }

      transportObj["properties"] = {
          1,
          nlohmann::json::array({0, "shellVersion", 0, APP_VERSION}),
          nlohmann::json::array({0, "BrowserExtensions", 0, extData}),
      };
      transportObj["signals"] = {
          nlohmann::json::array({0, "handleInboundJSONSignal"}),
      };
      nlohmann::json methods = nlohmann::json::array();
      methods.push_back(nlohmann::json::array({"onEvent", "handleInboundJSON"}));
      transportObj["methods"] = methods;
      root["data"]["transport"] = transportObj;

      shell::SendToWeb(root.dump());
      return;
    }

    if (type == 6 && j.contains("method")) {
      std::string methodName = j["method"].get<std::string>();
      if (methodName == "handleInboundJSON" || methodName == "onEvent") {
        if (j.contains("args") && j["args"].is_array() && !j["args"].empty()) {
          std::string ev;
          if (j["args"][0].is_string()) {
            ev = j["args"][0].get<std::string>();
          } else {
            ev = "Unknown";
          }

          std::vector<std::string> argVec;
          if (j["args"].size() > 1) {
            auto &second = j["args"][1];
            if (second.is_array()) {
              for (auto &x : second) {
                if (x.is_string()) {
                  argVec.push_back(x.get<std::string>());
                } else {
                  argVec.push_back(x.dump());
                }
              }
            } else if (second.is_string()) {
              argVec.push_back(second.get<std::string>());
            } else {
              argVec.push_back(second.dump());
            }
          }

          HandleEvent(ev, argVec);
        } else {
          std::cout << "[BRIDGE]: invokeMethod=handleInboundJSON => no args array?\n";
        }
      }
      return;
    }
    std::cout << "[BRIDGE]: Unknown Inbound event=" << msg << "\n";
  } catch (std::exception &ex) {
    std::cerr << "[BRIDGE]: JSON parse error: " << ex.what() << "\n";
  }
}
