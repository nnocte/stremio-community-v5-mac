#ifndef NET_H
#define NET_H

#include <string>

// Ported from src/utils/helpers.cpp of the Windows build, backed by
// NSURLSession instead of libcurl.
bool IsEndpointReachable(const std::string &url);
std::string GetFirstReachableUrl();
bool FetchAndParseWhitelist();
bool URLContainsAny(const std::string &url);

// True when a Stremio streaming server answers on the default local port.
bool StreamingServerResponds();

// Synchronous downloads (call from background threads only).
bool DownloadUrlToString(const std::string &url, std::string &out, int timeoutSeconds = 30);
bool DownloadUrlToFile(const std::string &url, const std::string &destination,
                       int timeoutSeconds = 300);

#endif // NET_H
