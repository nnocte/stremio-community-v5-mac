#include "Updater.h"

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>

#include "Bridge.h"
#include "Log.h"
#include "Net.h"
#include "NodeServer.h"
#include "Shell.h"
#include "Strings.h"

void RunAutoUpdaterOnce() {
  g_updaterRunning = true;
  std::cout << "[UPDATER]: Checking for updates" << std::endl;

  std::string versionContent;
  if (!DownloadUrlToString(g_updateUrl, versionContent, 15)) {
    AppendToCrashLog("[UPDATER]: Failed to download version.json");
    return;
  }

  nlohmann::json versionJson;
  try {
    versionJson = nlohmann::json::parse(versionContent);
  } catch (...) {
    AppendToCrashLog("[UPDATER]: version.json is not valid JSON");
    return;
  }
  if (!versionJson.contains("versionDesc") || !versionJson.contains("signature")) {
    AppendToCrashLog("[UPDATER]: version.json is missing fields");
    return;
  }

  std::string versionDescUrl = versionJson["versionDesc"].get<std::string>();
  std::string signatureBase64 = versionJson["signature"].get<std::string>();

  std::string detailsContent;
  if (!DownloadUrlToString(versionDescUrl, detailsContent, 30)) {
    AppendToCrashLog("[UPDATER]: Failed to download version details");
    return;
  }
  if (!VerifyUpdateSignature(detailsContent, signatureBase64)) {
    AppendToCrashLog("[UPDATER]: Signature verification failed");
    return;
  }

  nlohmann::json detailsJson;
  try {
    detailsJson = nlohmann::json::parse(detailsContent);
  } catch (...) {
    AppendToCrashLog("[UPDATER]: version details are not valid JSON");
    return;
  }

  std::string remoteShellVersion = detailsJson.value("shellVersion", "");
  bool needsFullUpdate = remoteShellVersion != APP_VERSION;
  auto files = detailsJson.value("files", nlohmann::json::object());

  std::filesystem::path tempDir = std::filesystem::path(NSTemporaryDirectory().UTF8String) /
                                 "stremio_updater";
  std::filesystem::create_directories(tempDir);

  if (needsFullUpdate || g_autoupdaterForceFull) {
    // Upstream publishes Windows artifacts only today; support macOS keys the
    // moment they appear and skip the prompt otherwise.
    std::string keys[] = {"macos-arm64", "macos-x64", "macos", "darwin-arm64", "darwin-x64"};
    bool downloaded = false;
    bool haveMacArtifact = false;
    std::filesystem::path downloadedPath;

    for (const auto &key : keys) {
      if (!files.contains(key)) continue;
      haveMacArtifact = true;
      const auto &entry = files[key];
      if (!entry.contains("url") || !entry.contains("checksum")) continue;

      std::string url = entry["url"].get<std::string>();
      std::string expectedChecksum = entry["checksum"].get<std::string>();
      std::string filename = url.substr(url.find_last_of('/') + 1);
      std::filesystem::path installerPath = tempDir / filename;

      if (std::filesystem::exists(installerPath) &&
          Sha256File(installerPath) == expectedChecksum) {
        downloaded = true;
        downloadedPath = installerPath;
      } else if (DownloadUrlToFile(url, installerPath.string(), 600)) {
        if (Sha256File(installerPath) == expectedChecksum) {
          downloaded = true;
          downloadedPath = installerPath;
        } else {
          AppendToCrashLog("[UPDATER]: Installer checksum mismatch");
          std::filesystem::remove(installerPath);
        }
      } else {
        AppendToCrashLog("[UPDATER]: Failed to download installer");
      }
      break;
    }

    if (downloaded) {
      g_installerPath = downloadedPath;
      std::cout << "[UPDATER]: Full update ready" << std::endl;
      nlohmann::json j;
      j["type"] = "requestUpdate";
      g_outboundMessages.push_back(j);
      shell::PostAppReady();
    } else if (!haveMacArtifact) {
      std::cout << "[UPDATER]: No macOS artifact published, skipping full update" << std::endl;
    }
  }

  if (!needsFullUpdate && files.contains("server.js")) {
    const auto &entry = files["server.js"];
    if (entry.contains("url") && entry.contains("checksum")) {
      std::string url = entry["url"].get<std::string>();
      std::string expectedChecksum = entry["checksum"].get<std::string>();

      // The portable_config copy takes precedence over the bundled server.js,
      // so app bundles installed under /Applications stay updatable.
      std::filesystem::path localFilePath =
          std::filesystem::path(g_configDir) / "server.js";

      if (!std::filesystem::exists(localFilePath) ||
          Sha256File(localFilePath) != expectedChecksum) {
        if (!DownloadUrlToFile(url, localFilePath.string(), 300)) {
          AppendToCrashLog("[UPDATER]: Failed to download server.js");
        } else if (Sha256File(localFilePath) != expectedChecksum) {
          AppendToCrashLog("[UPDATER]: Downloaded server.js is corrupted");
        } else {
          std::cout << "[UPDATER]: server.js updated" << std::endl;
          StopNodeServer();
          StartNodeServer();
        }
      }
    }
  }

  std::cout << "[UPDATER]: Update check done" << std::endl;
}

void RunInstallerAndExit() {
  if (g_installerPath.empty()) {
    AppendToCrashLog("[UPDATER]: Installer path not set");
    return;
  }

  std::string path = g_installerPath.string();
  std::string lower = ToLowerStr(path);
  if (lower.size() > 4 && (lower.rfind(".dmg") == lower.size() - 4 ||
                           lower.rfind(".pkg") == lower.size() - 4 ||
                           lower.rfind(".zip") == lower.size() - 4)) {
    std::cout << "[UPDATER]: Opening installer " << path << std::endl;
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
    [[NSWorkspace sharedWorkspace] openURL:url];
    dispatch_async(dispatch_get_main_queue(), ^{
      [NSApp terminate:nil];
    });
    return;
  }

  AppendToCrashLog("[UPDATER]: Unsupported installer type: " + path);
}
