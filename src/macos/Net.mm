#include "Net.h"

#include "Log.h"
#include "MacUtil.h"
#include "Shell.h"
#include "Strings.h"

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iostream>

#include "nlohmann/json.hpp"

namespace {

// Returns the HTTP status; 0 on transport error.
NSInteger RequestStatus(const std::string &url, NSString *method, NSTimeInterval timeout) {
  NSInteger status = 0;
  DownloadUrlSync(Utf8ToNs(url), timeout, &status, method);
  return status;
}

} // namespace

bool IsEndpointReachable(const std::string &url) {
  NSInteger status = RequestStatus(url, @"HEAD", 3.0);
  if (status >= 200 && status < 300) return true;
  // Some servers reject HEAD; fall back to a real GET.
  if (status == 405 || status == 501 || status == 0) {
    status = RequestStatus(url, @"GET", 3.0);
  }
  return status >= 200 && status < 300;
}

std::string GetFirstReachableUrl() {
  for (const auto &url : g_webuiUrls) {
    if (IsEndpointReachable(url)) {
      return url;
    }
  }
  return g_webuiUrls.empty() ? std::string() : g_webuiUrls[0];
}

bool URLContainsAny(const std::string &url) {
  if (std::find(g_domainWhitelist.begin(), g_domainWhitelist.end(), g_webuiUrl) ==
      g_domainWhitelist.end()) {
    g_domainWhitelist.push_back(g_webuiUrl);
  }
  return std::any_of(g_domainWhitelist.begin(), g_domainWhitelist.end(),
                     [&](const std::string &sub) {
                       return !sub.empty() && url.find(sub) != std::string::npos;
                     });
}

bool StreamingServerResponds() {
  NSInteger status = 0;
  NSData *data = DownloadUrlSync(@"http://127.0.0.1:11470/settings", 2.0, &status, nil);
  if (!data || status != 200) return false;
  // The streaming server answers with a JSON object; anything else on that port
  // is not ours to reuse.
  std::string body((const char *)data.bytes, (size_t)data.length);
  return body.find("\"options\"") != std::string::npos;
}

bool DownloadUrlToString(const std::string &url, std::string &out, int timeoutSeconds) {
  NSInteger status = 0;
  NSData *data = DownloadUrlSync(Utf8ToNs(url), (NSTimeInterval)timeoutSeconds, &status, nil);
  if (!data || status < 200 || status >= 300) return false;
  out.assign((const char *)data.bytes, (size_t)data.length);
  return true;
}

bool DownloadUrlToFile(const std::string &url, const std::string &destination,
                       int timeoutSeconds) {
  NSInteger status = 0;
  NSData *data = DownloadUrlSync(Utf8ToNs(url), (NSTimeInterval)timeoutSeconds, &status, nil);
  if (!data || status < 200 || status >= 300) return false;

  std::error_code ec;
  std::filesystem::path dest(destination);
  if (!dest.parent_path().empty()) {
    std::filesystem::create_directories(dest.parent_path(), ec);
  }

  std::ofstream f(destination, std::ios::binary | std::ios::trunc);
  if (!f) return false;
  f.write((const char *)data.bytes, (std::streamsize)data.length);
  return f.good();
}

bool FetchAndParseWhitelist() {
  std::string response;
  if (!DownloadUrlToString(g_extensionsDetailsUrl, response, 3)) {
    return false;
  }

  try {
    json j = json::parse(response);
    if (j.contains("domains") && j["domains"].is_array()) {
      g_domainWhitelist.clear();
      for (const auto &domain : j["domains"]) {
        if (domain.is_string()) {
          g_domainWhitelist.push_back(domain.get<std::string>());
        }
      }
      return true;
    }
  } catch (const std::exception &e) {
    std::cout << "[NET]: Failed json parsing of domain whitelist: " << e.what() << std::endl;
  }
  return false;
}
