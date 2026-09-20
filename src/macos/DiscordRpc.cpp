#include "DiscordRpc.h"

#include "Log.h"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include "nlohmann/json.hpp"

namespace {

constexpr int kOpHandshake = 0;
constexpr int kOpFrame = 1;
constexpr int kOpClose = 2;
constexpr int kOpPing = 3;
constexpr int kOpPong = 4;

struct ClientState {
  std::mutex mutex;
  std::condition_variable cv;
  int fd = -1;
  std::atomic<bool> running{false};
  std::atomic<bool> connected{false};
  std::thread reader;
  std::string applicationId;
  DiscordEventHandlers handlers{};
  uint64_t nonce = 1;

  // Pending SET_ACTIVITY payload; re-sent on reconnect.
  bool hasPresence = false;
  std::string presenceJson;
};

ClientState g_state;

bool WriteAll(int fd, const void *data, size_t size) {
  const char *ptr = static_cast<const char *>(data);
  while (size > 0) {
    ssize_t written = ::write(fd, ptr, size);
    if (written <= 0) {
      if (errno == EINTR) continue;
      return false;
    }
    ptr += written;
    size -= (size_t)written;
  }
  return true;
}

bool SendFrame(int fd, int opcode, const std::string &payload) {
  uint32_t header[2];
  header[0] = (uint32_t)opcode;
  header[1] = (uint32_t)payload.size();
  // Discord IPC uses little-endian framing.
  uint8_t bytes[8];
  for (int i = 0; i < 4; i++) {
    bytes[i] = (uint8_t)((header[0] >> (8 * i)) & 0xFF);
    bytes[4 + i] = (uint8_t)((header[1] >> (8 * i)) & 0xFF);
  }
  if (!WriteAll(fd, bytes, sizeof(bytes))) return false;
  if (!payload.empty() && !WriteAll(fd, payload.data(), payload.size())) return false;
  return true;
}

std::vector<std::string> SocketCandidates() {
  std::vector<std::string> dirs;
  if (const char *tmp = std::getenv("TMPDIR")) dirs.emplace_back(tmp);
  dirs.emplace_back("/tmp");

  std::vector<std::string> paths;
  for (const auto &dir : dirs) {
    for (int i = 0; i < 10; i++) {
      std::string base = dir;
      if (!base.empty() && base.back() == '/') base.pop_back();
      paths.push_back(base + "/discord-ipc-" + std::to_string(i));
    }
  }
  return paths;
}

int ConnectSocket() {
  for (const auto &path : SocketCandidates()) {
    int fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    if (path.size() >= sizeof(addr.sun_path)) {
      ::close(fd);
      continue;
    }
    std::strncpy(addr.sun_path, path.c_str(), sizeof(addr.sun_path) - 1);

    if (::connect(fd, (sockaddr *)&addr, sizeof(addr)) == 0) {
      return fd;
    }
    ::close(fd);
  }
  return -1;
}

bool PerformHandshake(int fd, const std::string &applicationId) {
  std::string payload = nlohmann::json{{"v", 1}, {"client_id", applicationId}}.dump();
  return SendFrame(fd, kOpHandshake, payload);
}

bool ReadExact(int fd, void *data, size_t size) {
  char *ptr = static_cast<char *>(data);
  while (size > 0) {
    ssize_t got = ::read(fd, ptr, size);
    if (got == 0) return false;
    if (got < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    ptr += got;
    size -= (size_t)got;
  }
  return true;
}

void HandleIncoming(const std::string &jsonText, ClientState &state) {
  nlohmann::json msg;
  try {
    msg = nlohmann::json::parse(jsonText);
  } catch (...) {
    return;
  }

  const std::string cmd = msg.value("cmd", "");
  if (cmd == "DISPATCH") {
    const std::string evt = msg.value("evt", "");
    if (evt == "READY" && state.handlers.ready) {
      DiscordUser user{};
      std::string username;
      if (msg.contains("data") && msg["data"].contains("user")) {
        const auto &u = msg["data"]["user"];
        username = u.value("username", "");
      }
      user.username = username.c_str();
      state.handlers.ready(&user);
    } else if (evt == "ERROR" && state.handlers.errored) {
      state.handlers.errored(msg.value("data", nlohmann::json::object()).value("code", 0),
                             msg.value("data", nlohmann::json::object()).value("message", "").c_str());
    }
  } else if (cmd == "PONG") {
    // ignore
  }
}

void ReaderLoop(ClientState *state) {
  const int backoffMs[] = {500, 1000, 2000, 5000, 10000};
  size_t attempt = 0;

  while (state->running.load()) {
    int fd = ConnectSocket();
    if (fd < 0) {
      std::this_thread::sleep_for(std::chrono::milliseconds(backoffMs[std::min(attempt, 4UL)]));
      if (attempt < 4) attempt++;
      continue;
    }

    if (!PerformHandshake(fd, state->applicationId)) {
      ::close(fd);
      continue;
    }

    {
      std::lock_guard<std::mutex> lock(state->mutex);
      state->fd = fd;
      state->connected = true;
      // Re-announce the last presence so reconnects keep the activity.
      if (state->hasPresence) {
        SendFrame(fd, kOpFrame, state->presenceJson);
      }
    }
    attempt = 0;

    std::vector<char> buffer;
    while (state->running.load()) {
      uint8_t header[8];
      if (!ReadExact(fd, header, sizeof(header))) break;

      uint32_t opcode = 0, length = 0;
      for (int i = 0; i < 4; i++) {
        opcode |= (uint32_t)header[i] << (8 * i);
        length |= (uint32_t)header[4 + i] << (8 * i);
      }
      if (length > 1 << 20) break;

      std::string payload(length, '\0');
      if (length > 0 && !ReadExact(fd, payload.data(), length)) break;

      if (opcode == kOpPing) {
        SendFrame(fd, kOpPong, {});
      } else if (opcode == kOpClose) {
        break;
      } else if (opcode == kOpFrame) {
        HandleIncoming(payload, *state);
      }
    }

    {
      std::lock_guard<std::mutex> lock(state->mutex);
      if (state->fd == fd) state->fd = -1;
      state->connected = false;
    }
    ::close(fd);

    if (state->handlers.disconnected) {
      state->handlers.disconnected(0, "discord ipc connection closed");
    }

    if (state->running.load()) {
      std::this_thread::sleep_for(std::chrono::milliseconds(backoffMs[std::min(attempt, 4UL)]));
      if (attempt < 4) attempt++;
    }
  }
}

std::string NextNonce(ClientState &state) {
  return std::to_string(::getpid()) + "-" + std::to_string(state.nonce++);
}

nlohmann::json PresenceToActivity(const DiscordRichPresence &presence) {
  nlohmann::json activity = nlohmann::json::object();
  if (presence.type >= 0) activity["type"] = presence.type;
  if (presence.details) activity["details"] = presence.details;
  if (presence.state) activity["state"] = presence.state;

  if (presence.startTimestamp > 0 || presence.endTimestamp > 0) {
    nlohmann::json timestamps = nlohmann::json::object();
    // Discord expects milliseconds.
    if (presence.startTimestamp > 0) timestamps["start"] = presence.startTimestamp * 1000;
    if (presence.endTimestamp > 0) timestamps["end"] = presence.endTimestamp * 1000;
    activity["timestamps"] = timestamps;
  }

  nlohmann::json assets = nlohmann::json::object();
  if (presence.largeImageKey) assets["large_image"] = presence.largeImageKey;
  if (presence.largeImageText) assets["large_text"] = presence.largeImageText;
  if (presence.smallImageKey) assets["small_image"] = presence.smallImageKey;
  if (presence.smallImageText) assets["small_text"] = presence.smallImageText;
  if (!assets.empty()) activity["assets"] = assets;

  nlohmann::json buttons = nlohmann::json::array();
  if (presence.button1Label && presence.button1Url) {
    buttons.push_back({{"label", presence.button1Label}, {"url", presence.button1Url}});
  }
  if (presence.button2Label && presence.button2Url) {
    buttons.push_back({{"label", presence.button2Label}, {"url", presence.button2Url}});
  }
  if (!buttons.empty()) activity["buttons"] = buttons;

  if (presence.partyId) {
    activity["party"] = {{"id", presence.partyId},
                         {"size", {presence.partySize, presence.partyMax}}};
  }
  if (presence.matchSecret) activity["secrets"]["match"] = presence.matchSecret;
  if (presence.joinSecret) activity["secrets"]["join"] = presence.joinSecret;
  if (presence.spectateSecret) activity["secrets"]["spectate"] = presence.spectateSecret;
  if (presence.instance) activity["instance"] = true;

  return activity;
}

} // namespace

extern "C" {

void Discord_Initialize(const char *applicationId, DiscordEventHandlers *handlers,
                        int, const char *) {
  if (!applicationId) return;
  if (g_state.running.load()) return;

  g_state.applicationId = applicationId;
  if (handlers) g_state.handlers = *handlers;

  g_state.running = true;
  g_state.reader = std::thread(ReaderLoop, &g_state);
  std::cout << "[DISCORD]: IPC client started" << std::endl;
}

void Discord_Shutdown(void) {
  if (!g_state.running.load()) return;
  g_state.running = false;

  {
    std::lock_guard<std::mutex> lock(g_state.mutex);
    if (g_state.fd >= 0) {
      SendFrame(g_state.fd, kOpClose, {});
      ::shutdown(g_state.fd, SHUT_RDWR);
    }
  }
  if (g_state.reader.joinable()) g_state.reader.join();

  {
    std::lock_guard<std::mutex> lock(g_state.mutex);
    if (g_state.fd >= 0) {
      ::close(g_state.fd);
      g_state.fd = -1;
    }
    g_state.connected = false;
  }
}

void Discord_RunCallbacks(void) {
  // Callbacks are dispatched from the reader thread on macOS.
}

void Discord_UpdatePresence(const DiscordRichPresence *presence) {
  if (!presence) return;

  nlohmann::json msg;
  {
    std::lock_guard<std::mutex> lock(g_state.mutex);
    msg = nlohmann::json{{"cmd", "SET_ACTIVITY"},
                         {"args", {{"pid", ::getpid()}, {"activity", PresenceToActivity(*presence)}}},
                         {"nonce", NextNonce(g_state)}};
    g_state.presenceJson = msg.dump();
    g_state.hasPresence = true;
    if (g_state.fd >= 0) {
      SendFrame(g_state.fd, kOpFrame, g_state.presenceJson);
    }
  }
}

void Discord_ClearPresence(void) {
  DiscordRichPresence empty{};
  empty.type = -1;
  Discord_UpdatePresence(&empty);
}

void Discord_Respond(const char *, int) {}

void Discord_UpdateHandlers(DiscordEventHandlers *handlers) {
  std::lock_guard<std::mutex> lock(g_state.mutex);
  if (handlers) g_state.handlers = *handlers;
}

} // extern "C"
