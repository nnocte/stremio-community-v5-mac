#include "NodeServer.h"

#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

#include "Bridge.h"
#include "Log.h"
#include "Net.h"
#include "Shell.h"
#include "Strings.h"

extern char **environ;

// Declared in Shell.h; defined here because this module owns the process.
std::atomic_bool g_nodeRunning = false;

namespace {

constexpr int kMaxRestarts = 3;
constexpr int kRestartDelaySeconds = 5;
constexpr int kReadyFallbackSeconds = 20;

std::atomic<pid_t> g_nodePid{-1};
std::atomic<bool> g_intentionalStop{false};
std::atomic<bool> g_ownedProcess{false};
std::atomic<bool> g_serverReadySent{false};
std::atomic<int> g_restartCount{0};

int g_outPipeRead = -1;
int g_inPipeWrite = -1;
std::thread g_outputThread;
std::thread g_supervisorThread;

std::string FindInPath(const std::string &name) {
  const char *pathEnv = std::getenv("PATH");
  if (!pathEnv) return {};
  std::string path(pathEnv);
  size_t start = 0;
  while (start <= path.size()) {
    size_t end = path.find(':', start);
    std::string dir = end == std::string::npos ? path.substr(start) : path.substr(start, end - start);
    if (!dir.empty()) {
      std::string candidate = dir + "/" + name;
      if (::access(candidate.c_str(), X_OK) == 0) return candidate;
    }
    if (end == std::string::npos) break;
    start = end + 1;
  }
  return {};
}

std::string FirstExisting(const std::vector<std::string> &candidates) {
  for (const auto &candidate : candidates) {
    if (!candidate.empty() && FileExists(candidate)) return candidate;
  }
  return {};
}

// Resolves the node runtime and the server.js script. Mirrors the Windows
// lookup order (next to the app first, then the Stremio service location) with
// macOS equivalents.
bool ResolveServerFiles(std::string &outRuntime, std::string &outScript) {
  std::string runtime = FirstExisting({
      g_resourcesDir + "/stremio-runtime",
      g_exeDir + "/stremio-runtime",
      "/Applications/Stremio.app/Contents/MacOS/stremio-runtime",
  });
  if (runtime.empty()) {
    runtime = FindInPath("stremio-runtime");
  }
  if (runtime.empty()) {
    runtime = FirstExisting({
        FindInPath("node"),
        "/opt/homebrew/bin/node",
        "/usr/local/bin/node",
        "/usr/bin/node",
    });
  }
  if (runtime.empty()) {
    AppendToCrashLog("[NODE]: No stremio-runtime or node executable found");
    return false;
  }

  std::string script = FirstExisting({
      g_configDir + "/server.js",
      g_resourcesDir + "/server.js",
      g_exeDir + "/server.js",
      "/Applications/Stremio.app/Contents/Resources/server.js",
  });
  if (script.empty()) {
    AppendToCrashLog("[NODE]: server.js not found (expected in " + g_resourcesDir + ")");
    return false;
  }

  outRuntime = runtime;
  outScript = script;
  return true;
}

std::string PidFilePath() { return g_configDir + "/streaming-server.pid"; }

bool ProcessMatchesServer(pid_t pid) {
  char command[4096] = {0};
  std::string cmd = "/bin/ps -p " + std::to_string(pid) + " -o command=";
  FILE *pipe = popen(cmd.c_str(), "r");
  if (!pipe) return false;
  size_t read = fread(command, 1, sizeof(command) - 1, pipe);
  pclose(pipe);
  command[read] = '\0';
  std::string line(command);
  return line.find("server.js") != std::string::npos;
}

// A force-killed previous instance can leave its streaming server behind; that
// server then steals port 11470 from the next launch (the web UI always talks
// to 11470, unlike the official shell which supports server-address events).
void KillStaleServerFromPidFile() {
  std::string content;
  if (!ReadFileUtf8(PidFilePath(), content)) return;

  pid_t pid = (pid_t)std::strtol(content.c_str(), nullptr, 10);
  if (pid <= 1) {
    std::filesystem::remove(PidFilePath());
    return;
  }
  if (::kill(pid, 0) != 0 || !ProcessMatchesServer(pid)) {
    std::filesystem::remove(PidFilePath());
    return;
  }

  std::cout << "[NODE]: killing stale streaming server (pid " << pid << ")" << std::endl;
  ::killpg(pid, SIGTERM);
  for (int i = 0; i < 30; i++) {
    if (::kill(pid, 0) != 0) break;
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
  }
  if (::kill(pid, 0) == 0) ::killpg(pid, SIGKILL);
  std::filesystem::remove(PidFilePath());
}

void WritePidFile(pid_t pid) {
  std::ofstream out(PidFilePath(), std::ios::trunc);
  if (out) out << pid;
}

void RemovePidFile() {
  std::error_code ec;
  std::filesystem::remove(PidFilePath(), ec);
}

void SendServerStartedOnce() {
  if (g_serverReadySent.exchange(true)) return;

  std::cout << "[NODE]: streaming server is ready" << std::endl;
  nlohmann::json j;
  j["type"] = "ServerStarted";
  g_outboundMessages.push_back(j);
  shell::PostAppReady();
}

void CloseServerHandles() {
  if (g_outputThread.joinable()) g_outputThread.join();
  if (g_outPipeRead >= 0) {
    ::close(g_outPipeRead);
    g_outPipeRead = -1;
  }
  if (g_inPipeWrite >= 0) {
    ::close(g_inPipeWrite);
    g_inPipeWrite = -1;
  }
}

void OutputThreadProc() {
  char buffer[1024];
  std::string lineBuffer;
  ssize_t readSize = 0;
  while ((readSize = ::read(g_outPipeRead, buffer, sizeof(buffer) - 1)) > 0) {
    buffer[readSize] = '\0';
    std::cout << "[node] " << buffer << std::flush;

    // The official shell waits for this line before announcing the server and
    // reads the bound address from it (the server picks another port when
    // 11470 is taken).
    lineBuffer.append(buffer, (size_t)readSize);
    size_t ready = lineBuffer.find("EngineFS server started at ");
    if (ready != std::string::npos) {
      std::string address = lineBuffer.substr(ready + 27);
      size_t end = address.find_first_of(" \r\n");
      if (end != std::string::npos) address = address.substr(0, end);
      if (address != "http://127.0.0.1:11470") {
        std::cout << "[NODE]: WARNING server bound to " << address
                  << " (the web UI expects port 11470)" << std::endl;
      }
      SendServerStartedOnce();
    }
    if (lineBuffer.size() > 8192) {
      lineBuffer.erase(0, lineBuffer.size() - 4096);
    }
  }
  std::cout << "[NODE]: output stream closed" << std::endl;
}

// Reaps the child process; restarts it a bounded number of times when it dies
// without the app shutting it down (same intent as the official shell's
// stay-alive timer).
void SupervisorLoop(pid_t pid) {
  int status = 0;
  while (true) {
    pid_t result = ::waitpid(pid, &status, 0);
    if (result == pid) break;
    if (result < 0 && errno == EINTR) continue;
    break;
  }

  g_nodePid = -1;
  if (g_intentionalStop.load() || !g_nodeRunning.load()) return;

  AppendToCrashLog("[NODE]: streaming server exited unexpectedly (status " +
                   std::to_string(status) + ")");

  if (g_restartCount.load() < kMaxRestarts) {
    g_restartCount++;
    std::this_thread::sleep_for(std::chrono::seconds(kRestartDelaySeconds));
    if (g_intentionalStop.load()) return;

    std::cout << "[NODE]: restarting streaming server (attempt " << g_restartCount.load() << ")"
              << std::endl;
    CloseServerHandles();
    if (g_supervisorThread.joinable()) g_supervisorThread.detach(); // detach ourselves
    StartNodeServer();
  }
}

void ReadyFallbackThread() {
  for (int waited = 0; waited < kReadyFallbackSeconds; waited++) {
    if (g_serverReadySent.load() || g_intentionalStop.load()) return;
    std::this_thread::sleep_for(std::chrono::seconds(1));
  }
  if (!g_serverReadySent.load() && g_nodePid.load() > 0) {
    std::cout << "[NODE]: ready line not seen, announcing anyway" << std::endl;
    SendServerStartedOnce();
  }
}

} // namespace

bool StartNodeServer() {
  if (g_nodeRunning.load()) return true;

  KillStaleServerFromPidFile();

  // Reuse a streaming server that is already running (e.g. the official
  // Stremio app); the web UI cannot be pointed at another port.
  if (StreamingServerResponds()) {
    std::cout << "[NODE]: reusing the streaming server already running on 11470" << std::endl;
    g_nodeRunning = true;
    g_ownedProcess = false;
    SendServerStartedOnce();
    return true;
  }

  std::string runtime, script;
  if (!ResolveServerFiles(runtime, script)) {
    return false;
  }

  int outPipe[2] = {-1, -1};
  int inPipe[2] = {-1, -1};
  if (::pipe(outPipe) != 0) {
    AppendToCrashLog("[NODE]: pipe() failed");
    return false;
  }
  if (::pipe(inPipe) != 0) {
    AppendToCrashLog("[NODE]: pipe() failed");
    ::close(outPipe[0]);
    ::close(outPipe[1]);
    return false;
  }

  // The server locates addons via CORS-free local HTTP, same as on Windows.
  ::setenv("NO_CORS", "1", 1);

  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO);
  posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDERR_FILENO);
  posix_spawn_file_actions_adddup2(&actions, inPipe[0], STDIN_FILENO);
  posix_spawn_file_actions_addclose(&actions, outPipe[0]);
  posix_spawn_file_actions_addclose(&actions, outPipe[1]);
  posix_spawn_file_actions_addclose(&actions, inPipe[0]);
  posix_spawn_file_actions_addclose(&actions, inPipe[1]);
  std::string workingDir = std::filesystem::path(script).parent_path().string();
  if (!workingDir.empty()) {
#if defined(__MAC_OS_X_VERSION_MAX_ALLOWED) && __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
    posix_spawn_file_actions_addchdir(&actions, workingDir.c_str());
#else
    posix_spawn_file_actions_addchdir_np(&actions, workingDir.c_str());
#endif
  }

  posix_spawnattr_t attributes;
  posix_spawnattr_init(&attributes);
  short flags = POSIX_SPAWN_SETPGROUP;
  posix_spawnattr_setflags(&attributes, flags);
  posix_spawnattr_setpgroup(&attributes, 0); // own process group => killpg on stop

  std::vector<char *> argv;
  argv.push_back(const_cast<char *>(runtime.c_str()));
  argv.push_back(const_cast<char *>(script.c_str()));
  argv.push_back(nullptr);

  pid_t pid = -1;
  int spawnResult = posix_spawn(&pid, runtime.c_str(), &actions, &attributes, argv.data(), environ);

  posix_spawn_file_actions_destroy(&actions);
  posix_spawnattr_destroy(&attributes);

  if (spawnResult != 0) {
    AppendToCrashLog(std::string("[NODE]: posix_spawn failed: ") + std::strerror(spawnResult));
    ::close(outPipe[0]);
    ::close(outPipe[1]);
    ::close(inPipe[0]);
    ::close(inPipe[1]);
    return false;
  }

  ::close(outPipe[1]);
  ::close(inPipe[0]);

  g_intentionalStop = false;
  g_serverReadySent = false;
  g_ownedProcess = true;
  g_nodePid = pid;
  WritePidFile(pid);
  g_outPipeRead = outPipe[0];
  g_inPipeWrite = inPipe[1];
  g_nodeRunning = true;
  g_outputThread = std::thread(OutputThreadProc);
  g_supervisorThread = std::thread(SupervisorLoop, pid);
  std::thread(ReadyFallbackThread).detach();

  std::cout << "[NODE]: started " << runtime << " " << script << " (pid " << pid << ")"
            << std::endl;
  return true;
}

void StopNodeServer() {
  if (!g_nodeRunning.exchange(false)) return;
  g_intentionalStop = true;

  if (!g_ownedProcess.load()) {
    std::cout << "[NODE]: leaving the reused streaming server running" << std::endl;
    return;
  }

  pid_t pid = g_nodePid.load();
  if (pid > 0) {
    ::killpg(pid, SIGTERM);

    bool exited = false;
    for (int i = 0; i < 50; i++) { // up to 5s
      if (g_nodePid.load() != pid) {
        exited = true;
        break;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    if (!exited) {
      ::killpg(pid, SIGKILL);
    }
  }

  if (g_supervisorThread.joinable()) g_supervisorThread.join();
  CloseServerHandles();
  RemovePidFile();
  g_restartCount = 0;
  std::cout << "[NODE]: stopped" << std::endl;
}
