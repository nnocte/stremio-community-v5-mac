#include "MPV.h"

#include "Bridge.h"
#include "Log.h"
#include "MediaKeys.h"
#include "Power.h"
#include "Shell.h"
#include "Strings.h"

#include <cctype>
#include <condition_variable>
#include <deque>
#include <filesystem>
#include <iostream>
#include <mutex>
#include <thread>

#include <dispatch/dispatch.h>

namespace {

// Latest playback state for the Now Playing widget.
std::mutex g_nowPlayingMutex;
std::string g_nowPlayingTitle;
double g_nowPlayingDuration = 0;
double g_nowPlayingPosition = 0;
bool g_nowPlayingPaused = true;

void RefreshNowPlaying() {
  std::lock_guard<std::mutex> lock(g_nowPlayingMutex);
  UpdateNowPlaying(g_nowPlayingTitle, g_nowPlayingDuration, g_nowPlayingPosition,
                   g_nowPlayingPaused);
}

// ---------------------------------------------------------------------------
// Serialized command worker
//
// The Windows build spawned a detached thread per command; a single ordered
// worker keeps the same non-blocking behaviour without thread churn and
// guarantees that e.g. aid/sid sets are applied in order.
// ---------------------------------------------------------------------------
enum class JobKind { Command, SetProp, ObserveProp };

struct Job {
  JobKind kind;
  std::vector<std::string> args;
};

std::mutex g_jobMutex;
std::condition_variable g_jobCv;
std::deque<Job> g_jobs;
std::thread g_jobThread;
std::atomic<bool> g_jobThreadRunning{false};

void JobWorker() {
  while (true) {
    Job job;
    {
      std::unique_lock<std::mutex> lock(g_jobMutex);
      g_jobCv.wait(lock, [] { return !g_jobs.empty() || !g_jobThreadRunning.load(); });
      if (!g_jobThreadRunning.load() && g_jobs.empty()) return;
      job = std::move(g_jobs.front());
      g_jobs.pop_front();
    }

    if (!g_mpv) continue;

    switch (job.kind) {
      case JobKind::Command: {
        if (job.args.empty()) break;
        std::vector<const char *> cargs;
        cargs.reserve(job.args.size() + 1);
        for (auto &s : job.args) cargs.push_back(s.c_str());
        cargs.push_back(nullptr);
        int err = mpv_command(g_mpv, cargs.data());
        if (err < 0) {
          std::cerr << "[MPV]: command failed: " << mpv_error_string(err) << "\n";
        }
        break;
      }
      case JobKind::SetProp: {
        if (job.args.size() < 2) break;
        std::string val = job.args[1];
        if (val == "true") val = "yes";
        if (val == "false") val = "no";
        int err = mpv_set_property_string(g_mpv, job.args[0].c_str(), val.c_str());
        if (err < 0) {
          std::cerr << "[MPV]: set property " << job.args[0] << " failed: " << mpv_error_string(err)
                    << "\n";
        }
        break;
      }
      case JobKind::ObserveProp: {
        if (job.args.empty()) break;
        const std::string &name = job.args[0];
        g_observedProps.insert(name);
        mpv_observe_property(g_mpv, 0, name.c_str(), MPV_FORMAT_NODE);
        std::cout << "[MPV]: Observing prop=" << name << "\n";
        break;
      }
    }
  }
}

void EnsureJobWorker() {
  if (g_jobThreadRunning.load()) return;
  g_jobThreadRunning = true;
  g_jobThread = std::thread(JobWorker);
}

void EnqueueJob(Job job) {
  EnsureJobWorker();
  {
    std::lock_guard<std::mutex> lock(g_jobMutex);
    g_jobs.push_back(std::move(job));
  }
  g_jobCv.notify_one();
}

// ---------------------------------------------------------------------------
// mpv node -> JSON (same mapping as the Windows build)
// ---------------------------------------------------------------------------
nlohmann::json MpvNodeToJson(const mpv_node *node);

nlohmann::json MpvNodeArrayToJson(const mpv_node_list *list) {
  nlohmann::json j = nlohmann::json::array();
  if (!list) return j;
  for (int i = 0; i < list->num; i++) {
    j.push_back(MpvNodeToJson(&list->values[i]));
  }
  return j;
}

nlohmann::json MpvNodeMapToJson(const mpv_node_list *list) {
  nlohmann::json j = nlohmann::json::object();
  if (!list) return j;
  for (int i = 0; i < list->num; i++) {
    const char *key = (list->keys && list->keys[i]) ? list->keys[i] : "";
    j[key] = MpvNodeToJson(&list->values[i]);
  }
  return j;
}

nlohmann::json MpvNodeToJson(const mpv_node *node) {
  if (!node) return nullptr;

  switch (node->format) {
    case MPV_FORMAT_STRING:
      return node->u.string ? node->u.string : "";
    case MPV_FORMAT_INT64:
      return (long long)node->u.int64;
    case MPV_FORMAT_DOUBLE:
      return node->u.double_;
    case MPV_FORMAT_FLAG:
      return (bool)node->u.flag;
    case MPV_FORMAT_NODE_ARRAY:
      return MpvNodeArrayToJson(node->u.list);
    case MPV_FORMAT_NODE_MAP:
      return MpvNodeMapToJson(node->u.list);
    default:
      return "<unhandled mpv_node format>";
  }
}

std::string CapitalizeFirstLetter(const std::string &input) {
  if (input.empty()) return input;
  std::string result = input;
  result[0] = (char)std::toupper((unsigned char)result[0]);
  return result;
}

// mpv calls this from its playback threads; libmpv requires that the wakeup
// callback does not call mpv_* functions, so marshal to the main queue (the
// equivalent of the Windows WM_MPV_WAKEUP message).
void MpvWakeup(void * /*ctx*/) {
  dispatch_async(dispatch_get_main_queue(), ^{
    HandleMpvEvents();
  });
}

} // namespace

void HandleMpvEvents() {
  if (!g_mpv) return;
  while (true) {
    mpv_event *ev = mpv_wait_event(g_mpv, 0);
    if (!ev || ev->event_id == MPV_EVENT_NONE) break;

    if (ev->error < 0) {
      std::cerr << "[MPV]: event error=" << mpv_error_string(ev->error) << "\n";
    }

    switch (ev->event_id) {
      case MPV_EVENT_PROPERTY_CHANGE: {
        mpv_event_property *prop = (mpv_event_property *)ev->data;
        if (!prop || !prop->name) break;

        json j;
        j["type"] = "mpv-prop-change";
        j["id"] = (int64_t)ev->reply_userdata;
        j["name"] = prop->name;
        if (ev->error < 0) j["error"] = mpv_error_string(ev->error);

        switch (prop->format) {
          case MPV_FORMAT_INT64:
            if (prop->data) {
              j["data"] = (long long)(*(int64_t *)prop->data);
            } else {
              j["data"] = nullptr;
            }
            break;
          case MPV_FORMAT_DOUBLE:
            if (prop->data) {
              j["data"] = *(double *)prop->data;
            } else {
              j["data"] = nullptr;
            }
            break;
          case MPV_FORMAT_FLAG:
            j["data"] = prop->data ? (*(int *)prop->data != 0) : false;
            break;
          case MPV_FORMAT_STRING: {
            const char *s = prop->data ? *(char **)prop->data : nullptr;
            j["data"] = s ? s : "";
            break;
          }
          case MPV_FORMAT_NODE:
            j["data"] = MpvNodeToJson((mpv_node *)prop->data);
            break;
          default:
            j["data"] = nullptr;
            break;
        }

        if (j["name"] == "volume" && g_initialSet && j["data"].is_number()) {
          g_currentVolume = j["data"].get<int>();
        }
        if (j["name"] == "pause") {
          bool paused = j["data"].is_boolean() ? j["data"].get<bool>() : true;
          char *path = g_mpv ? mpv_get_property_string(g_mpv, "path") : nullptr;
          bool hasVideo = path != nullptr;
          mpv_free(path);
          SetDisplaySleepBlocked(hasVideo && !paused);
          {
            std::lock_guard<std::mutex> lock(g_nowPlayingMutex);
            g_nowPlayingPaused = paused;
          }
          RefreshNowPlaying();
        } else if (j["name"] == "duration") {
          {
            std::lock_guard<std::mutex> lock(g_nowPlayingMutex);
            g_nowPlayingDuration = j["data"].is_number() ? j["data"].get<double>() : 0;
          }
          RefreshNowPlaying();
        } else if (j["name"] == "time-pos") {
          {
            std::lock_guard<std::mutex> lock(g_nowPlayingMutex);
            g_nowPlayingPosition = j["data"].is_number() ? j["data"].get<double>() : 0;
          }
          RefreshNowPlaying();
        } else if (j["name"] == "media-title" || j["name"] == "metadata") {
          if (j["data"].is_string()) {
            std::lock_guard<std::mutex> lock(g_nowPlayingMutex);
            g_nowPlayingTitle = j["data"].get<std::string>();
          }
          RefreshNowPlaying();
        }
        SendToJS("mpv-prop-change", j);
        break;
      }
      case MPV_EVENT_END_FILE: {
        SetDisplaySleepBlocked(false);
        {
          std::lock_guard<std::mutex> lock(g_nowPlayingMutex);
          g_nowPlayingDuration = 0;
          g_nowPlayingPosition = 0;
          g_nowPlayingTitle.clear();
        }
        RefreshNowPlaying();
        mpv_event_end_file *ef = (mpv_event_end_file *)ev->data;
        nlohmann::json j;
        j["type"] = "mpv-event-ended";
        switch (ef->reason) {
          case MPV_END_FILE_REASON_EOF:
            j["reason"] = "quit";
            SendToJS("mpv-event-ended", j);
            break;
          case MPV_END_FILE_REASON_ERROR: {
            std::string errorString = mpv_error_string(ef->error);
            std::string capitalizedErrorString = CapitalizeFirstLetter(errorString);
            j["reason"] = "error";
            if (ef->error < 0) j["error"] = capitalizedErrorString;
            SendToJS("mpv-event-ended", j);
            AppendToCrashLog("[MPV]: " + capitalizedErrorString);
            break;
          }
          default:
            j["reason"] = "other";
            break;
        }
        break;
      }
      case MPV_EVENT_SHUTDOWN: {
        std::cout << "[MPV]: EVENT_SHUTDOWN => terminate\n";
        mpv_terminate_destroy(g_mpv);
        g_mpv = nullptr;
        break;
      }
      default:
        break;
    }
  }
}

void HandleMpvCommand(const std::vector<std::string> &args) {
  if (args.empty()) return;
  EnqueueJob(Job{JobKind::Command, args});
}

void HandleMpvSetProp(const std::vector<std::string> &args) {
  if (args.size() < 2) return;
  EnqueueJob(Job{JobKind::SetProp, args});
}

void HandleMpvObserveProp(const std::vector<std::string> &args) {
  if (args.empty()) return;
  EnqueueJob(Job{JobKind::ObserveProp, args});
}

void pauseMPV(bool allowed) {
  if (!allowed) return;
  HandleMpvSetProp({"pause", "true"});
}

bool InitMPV() {
  g_mpv = mpv_create();
  if (!g_mpv) {
    std::cerr << "[MPV]: mpv_create failed\n";
    AppendToCrashLog("[MPV]: Create failed");
    return false;
  }

  // portable_config is the mpv config-dir, exactly like on Windows.
  std::error_code ec;
  std::filesystem::create_directories(g_configDir, ec);
  if (!g_configDir.empty()) {
    mpv_set_option_string(g_mpv, "config-dir", g_configDir.c_str());
  }
  mpv_set_option_string(g_mpv, "load-scripts", "yes");
  mpv_set_option_string(g_mpv, "config", "yes");
  mpv_set_option_string(g_mpv, "terminal", "yes");
  mpv_set_option_string(g_mpv, "msg-level", "all=v");
  mpv_set_option_string(g_mpv, "idle", "yes");

  // Render API output (see VideoView.mm); the web UI's later `vo` set-props
  // are forced back to this value in Bridge.cpp.
  mpv_set_option_string(g_mpv, "vo", "libmpv");
  mpv_set_option_string(g_mpv, "osc", "no");
  mpv_set_option_string(g_mpv, "input-default-bindings", "yes");
  mpv_set_option_string(g_mpv, "input-vo-keyboard", "yes");

  // demux/caching (same values as the Windows build)
  mpv_set_option_string(g_mpv, "demuxer-lavf-probesize", "524288");
  mpv_set_option_string(g_mpv, "demuxer-lavf-analyzeduration", "0.5");
  mpv_set_option_string(g_mpv, "demuxer-max-bytes", "300000000");
  mpv_set_option_string(g_mpv, "demuxer-max-packets", "150000000");
  mpv_set_option_string(g_mpv, "cache", "yes");
  mpv_set_option_string(g_mpv, "cache-pause", "no");
  mpv_set_option_string(g_mpv, "cache-secs", "60");
  mpv_set_option_string(g_mpv, "vd-lavc-threads", "0");
  mpv_set_option_string(g_mpv, "ad-lavc-threads", "0");
  mpv_set_option_string(g_mpv, "audio-fallback-to-null", "yes");
  // Required to change hwdec at runtime (the web UI toggles hardware decoding).
  mpv_set_option_string(g_mpv, "gpu-hwdec-interop", "auto");
  mpv_set_option_string(g_mpv, "audio-client-name", APP_NAME);
  mpv_set_option_string(g_mpv, "title", APP_NAME);

  mpv_set_wakeup_callback(g_mpv, MpvWakeup, nullptr);

  if (mpv_initialize(g_mpv) < 0) {
    std::cerr << "[MPV]: mpv_initialize failed\n";
    AppendToCrashLog("[MPV]: Initialize failed");
    mpv_terminate_destroy(g_mpv);
    g_mpv = nullptr;
    return false;
  }

  return true;
}

void CleanupMPV() {
  if (g_jobThreadRunning.load()) {
    g_jobThreadRunning = false;
    g_jobCv.notify_all();
    if (g_jobThread.joinable()) g_jobThread.join();
  }

  if (g_mpv) {
    mpv_terminate_destroy(g_mpv);
    g_mpv = nullptr;
  }
}
