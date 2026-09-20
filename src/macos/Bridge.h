#ifndef BRIDGE_H
#define BRIDGE_H

#include <string>
#include <vector>

#include "nlohmann/json.hpp"

// Ported from src/ui/mainwindow.cpp (Windows). The wire format is unchanged:
//   JS -> native  {type:6, object:"transport", method:"handleInboundJSON", args:[event, args]}
//   native -> JS  {type:1, object:"transport", id, args:[event, data]}
void SendToJS(const std::string &eventName, const nlohmann::json &eventData);
void HandleEvent(const std::string &ev, std::vector<std::string> &args);
void HandleInboundJSON(const std::string &msg);

#endif // BRIDGE_H
