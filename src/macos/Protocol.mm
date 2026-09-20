#include "Protocol.h"

#include <fcntl.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <atomic>
#include <cstring>
#include <iostream>
#include <thread>
#include <vector>

#include "AppWindow.h"
#include "Log.h"
#include "Shell.h"
#include "Strings.h"
#include "WebShell.h"

#include "nlohmann/json.hpp"

namespace {

int g_lockFd = -1;
int g_listenFd = -1;
bool g_isOwner = false;
std::atomic<bool> g_acceptRunning{false};
std::thread g_acceptThread;

std::string LockPath() { return g_configDir + "/instance.lock"; }
std::string SocketPath() { return g_configDir + "/instance.sock"; }

// Same filter the Windows build applies when looking at its command line.
bool IsProtocolArgument(const std::string &arg) {
  return arg.rfind("stremio://", 0) == 0 || arg.rfind("magnet:", 0) == 0 || FileExists(arg);
}

std::vector<std::string> CollectProtocolArguments(int argc, char *argv[]) {
  std::vector<std::string> out;
  for (int i = 1; i < argc; i++) {
    std::string arg(argv[i]);
    if (IsProtocolArgument(arg)) out.push_back(arg);
  }
  return out;
}

bool ForwardToRunningInstance(const std::vector<std::string> &args) {
  int fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return false;

  sockaddr_un addr{};
  addr.sun_family = AF_UNIX;
  std::string path = SocketPath();
  if (path.size() >= sizeof(addr.sun_path)) {
    ::close(fd);
    return false;
  }
  std::strncpy(addr.sun_path, path.c_str(), sizeof(addr.sun_path) - 1);

  if (::connect(fd, (sockaddr *)&addr, sizeof(addr)) != 0) {
    ::close(fd);
    return false;
  }

  nlohmann::json payload;
  payload["args"] = args;
  std::string line = payload.dump() + "\n";
  ssize_t written = ::write(fd, line.data(), line.size());
  ::close(fd);
  return written == (ssize_t)line.size();
}

void AcceptLoop() {
  while (g_acceptRunning.load()) {
    int client = ::accept(g_listenFd, nullptr, nullptr);
    if (client < 0) {
      if (g_acceptRunning.load()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
      }
      continue;
    }

    std::string buffer;
    char chunk[1024];
    ssize_t got = 0;
    while ((got = ::read(client, chunk, sizeof(chunk))) > 0) {
      buffer.append(chunk, (size_t)got);
      if (buffer.find('\n') != std::string::npos) break;
    }
    ::close(client);

    if (buffer.empty()) continue;

    try {
      json payload = json::parse(buffer);
      std::vector<std::string> args;
      if (payload.contains("args") && payload["args"].is_array()) {
        for (const auto &item : payload["args"]) {
          if (item.is_string()) args.push_back(item.get<std::string>());
        }
      }

      std::vector<std::string> copy = args;
      dispatch_async(dispatch_get_main_queue(), ^{
        for (const auto &arg : copy) {
          std::cout << "[PROTOCOL]: Received argument " << arg << std::endl;
          if (!g_isAppReady) {
            g_launchProtocol = arg;
          } else {
            HandleLaunchProtocol(arg);
          }
        }
        shell::ShowMainWindow();
      });
    } catch (const std::exception &e) {
      AppendToCrashLog(std::string("[PROTOCOL]: Bad forward payload: ") + e.what());
    }
  }
}

} // namespace

bool AcquireSingleInstance(int argc, char *argv[]) {
  std::vector<std::string> args = CollectProtocolArguments(argc, argv);

  // 1) Ownership lock. Released automatically when the process exits.
  g_lockFd = ::open(LockPath().c_str(), O_CREAT | O_RDWR, 0644);
  if (g_lockFd < 0) {
    AppendToCrashLog("[PROTOCOL]: Could not open lock file, continuing without single instance");
    return true;
  }

  if (::flock(g_lockFd, LOCK_EX | LOCK_NB) != 0) {
    std::cout << "[PROTOCOL]: Another instance is running, forwarding arguments" << std::endl;
    if (!args.empty() && !ForwardToRunningInstance(args)) {
      AppendToCrashLog("[PROTOCOL]: Failed to forward arguments to the running instance");
    }
    ::close(g_lockFd);
    g_lockFd = -1;
    return false;
  }

  // 2) We own the lock: publish the forwarding socket. A stale socket from a
  //    crashed instance is removed first.
  ::unlink(SocketPath().c_str());
  g_listenFd = ::socket(AF_UNIX, SOCK_STREAM, 0);
  if (g_listenFd < 0) {
    AppendToCrashLog("[PROTOCOL]: Could not create ipc socket");
    return true;
  }

  sockaddr_un addr{};
  addr.sun_family = AF_UNIX;
  std::string path = SocketPath();
  if (path.size() >= sizeof(addr.sun_path)) {
    AppendToCrashLog("[PROTOCOL]: ipc socket path too long");
    return true;
  }
  std::strncpy(addr.sun_path, path.c_str(), sizeof(addr.sun_path) - 1);

  if (::bind(g_listenFd, (sockaddr *)&addr, sizeof(addr)) != 0 ||
      ::listen(g_listenFd, 16) != 0) {
    AppendToCrashLog("[PROTOCOL]: Could not bind ipc socket");
    ::close(g_listenFd);
    g_listenFd = -1;
    return true;
  }

  // Remember the protocol argument for the first instance as well (the
  // Windows build stores it in g_launchProtocol during CheckSingleInstance).
  if (!args.empty()) {
    g_launchProtocol = args[0];
  }

  g_isOwner = true;
  g_acceptRunning = true;
  g_acceptThread = std::thread(AcceptLoop);
  return true;
}

void ReleaseSingleInstance() {
  // Only the instance that owns the lock may remove the socket; a forwarding
  // instance calls Cleanup() via atexit and must not disturb the owner.
  if (!g_isOwner) return;

  g_acceptRunning = false;
  if (g_listenFd >= 0) {
    ::shutdown(g_listenFd, SHUT_RDWR);
    ::close(g_listenFd);
    g_listenFd = -1;
  }
  if (g_acceptThread.joinable()) g_acceptThread.join();
  ::unlink(SocketPath().c_str());
  if (g_lockFd >= 0) {
    ::flock(g_lockFd, LOCK_UN);
    ::close(g_lockFd);
    g_lockFd = -1;
  }
}
