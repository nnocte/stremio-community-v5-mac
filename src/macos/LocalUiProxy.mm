#include "LocalUiProxy.h"

#import <Foundation/Foundation.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

#include <atomic>
#include <cstring>
#include <iostream>
#include <mutex>
#include <sstream>
#include <thread>
#include <vector>

#include "Log.h"
#include "MacUtil.h"
#include "Strings.h"

namespace {

int g_listenFd = -1;
int g_port = 0;
std::atomic<bool> g_running{false};
std::thread g_acceptThread;
std::mutex g_upstreamMutex;
std::string g_upstreamBase; // https://host[:port] (no trailing slash)
std::string g_localBase;    // http://127.0.0.1:<port>

struct HttpRequest {
  std::string method;
  std::string target;
  std::vector<std::pair<std::string, std::string>> headers;
  std::string body;

  std::string Header(const std::string &name) const {
    std::string lower = ToLowerStr(name);
    for (const auto &[key, value] : headers) {
      if (ToLowerStr(key) == lower) return value;
    }
    return {};
  }
};

struct HttpResponse {
  long status = 502;
  std::string reason = "Bad Gateway";
  std::vector<std::pair<std::string, std::string>> headers;
  std::string body;
  bool noBody = false;
};

bool SendAll(int fd, const char *data, size_t size) {
  while (size > 0) {
    ssize_t written = ::send(fd, data, size, 0);
    if (written <= 0) {
      if (errno == EINTR) continue;
      return false;
    }
    data += written;
    size -= (size_t)written;
  }
  return true;
}

bool ReadRequest(int fd, HttpRequest &request) {
  std::string buffer;
  char chunk[4096];

  // Read until the end of the headers.
  size_t headerEnd = std::string::npos;
  while (headerEnd == std::string::npos) {
    ssize_t got = ::recv(fd, chunk, sizeof(chunk), 0);
    if (got <= 0) return false;
    buffer.append(chunk, (size_t)got);
    headerEnd = buffer.find("\r\n\r\n");
    if (buffer.size() > 1024 * 1024) return false; // header flood guard
  }

  std::istringstream headerStream(buffer.substr(0, headerEnd));
  std::string line;
  if (!std::getline(headerStream, line)) return false;
  if (!line.empty() && line.back() == '\r') line.pop_back();

  {
    std::istringstream requestLine(line);
    if (!(requestLine >> request.method >> request.target)) return false;
  }

  while (std::getline(headerStream, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.empty()) continue;
    size_t colon = line.find(':');
    if (colon == std::string::npos) continue;
    std::string name = line.substr(0, colon);
    std::string value = line.substr(colon + 1);
    size_t start = value.find_first_not_of(" \t");
    if (start != std::string::npos) value = value.substr(start);
    request.headers.emplace_back(name, value);
  }

  request.body = buffer.substr(headerEnd + 4);

  std::string lengthHeader = request.Header("Content-Length");
  if (!lengthHeader.empty()) {
    size_t expected = (size_t)std::strtoul(lengthHeader.c_str(), nullptr, 10);
    while (request.body.size() < expected) {
      ssize_t got = ::recv(fd, chunk, sizeof(chunk), 0);
      if (got <= 0) break;
      request.body.append(chunk, (size_t)got);
    }
  }
  return true;
}

bool IsLocalOrigin(const std::string &value) {
  std::lock_guard<std::mutex> lock(g_upstreamMutex);
  return !g_localBase.empty() && value.rfind(g_localBase, 0) == 0;
}

std::string RewriteToUpstream(const std::string &value) {
  std::lock_guard<std::mutex> lock(g_upstreamMutex);
  if (g_localBase.empty() || value.rfind(g_localBase, 0) != 0) return value;
  return g_upstreamBase + value.substr(g_localBase.size());
}

std::string RewriteToLocal(const std::string &value) {
  std::lock_guard<std::mutex> lock(g_upstreamMutex);
  if (g_upstreamBase.empty() || value.rfind(g_upstreamBase, 0) != 0) return value;
  return g_localBase + value.substr(g_upstreamBase.size());
}

HttpResponse ForwardRequest(const HttpRequest &request) {
  HttpResponse response;

  std::string upstream;
  {
    std::lock_guard<std::mutex> lock(g_upstreamMutex);
    upstream = g_upstreamBase;
  }
  if (upstream.empty()) {
    response.reason = "Proxy Not Ready";
    return response;
  }

  std::string target = request.target;
  if (target.rfind("http://", 0) == 0 || target.rfind("https://", 0) == 0) {
    // Absolute-form request: only our upstream is allowed.
    if (target.rfind(upstream, 0) != 0) {
      response.status = 400;
      response.reason = "Bad Request";
      return response;
    }
  } else {
    if (target.empty() || target[0] != '/') target = "/" + target;
    target = upstream + target;
  }

  NSURL *url = [NSURL URLWithString:Utf8ToNs(target)];
  if (!url) {
    response.status = 400;
    response.reason = "Bad Request";
    return response;
  }

  NSMutableURLRequest *forward = [NSMutableURLRequest requestWithURL:url];
  forward.HTTPMethod = Utf8ToNs(request.method);
  forward.timeoutInterval = 30;

  for (const auto &[name, value] : request.headers) {
    std::string lower = ToLowerStr(name);
    // Hop-by-hop and body framing headers are managed by NSURLSession.
    if (lower == "host" || lower == "connection" || lower == "content-length" ||
        lower == "accept-encoding" || lower == "transfer-encoding" || lower == "upgrade") {
      continue;
    }
    if (lower == "origin" && IsLocalOrigin(value)) {
      [forward setValue:Utf8ToNs(RewriteToUpstream(value)) forHTTPHeaderField:Utf8ToNs(name)];
      continue;
    }
    if (lower == "referer" && IsLocalOrigin(value)) {
      [forward setValue:Utf8ToNs(RewriteToUpstream(value)) forHTTPHeaderField:Utf8ToNs(name)];
      continue;
    }
    [forward setValue:Utf8ToNs(value) forHTTPHeaderField:Utf8ToNs(name)];
  }

  if (!request.body.empty()) {
    forward.HTTPBody = [NSData dataWithBytes:request.body.data() length:request.body.size()];
  }

  NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
  configuration.timeoutIntervalForRequest = 30;
  configuration.HTTPShouldSetCookies = NO;
  configuration.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
  NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];

  __block NSData *responseData = nil;
  __block NSHTTPURLResponse *httpResponse = nil;
  __block NSError *requestError = nil;
  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

  [[session dataTaskWithRequest:forward
             completionHandler:^(NSData *data, NSURLResponse *urlResponse, NSError *error) {
               responseData = data;
               httpResponse = (NSHTTPURLResponse *)urlResponse;
               requestError = error;
               dispatch_semaphore_signal(semaphore);
             }] resume];
  dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(35 * NSEC_PER_SEC)));

  if (requestError || !httpResponse) {
    response.status = 502;
    response.reason = "Bad Gateway";
    response.body = requestError ? NsToUtf8(requestError.localizedDescription) : "upstream error";
    response.headers.emplace_back("Content-Type", "text/plain; charset=utf-8");
    return response;
  }

  response.status = httpResponse.statusCode;
  response.reason = "OK";

  for (id key in httpResponse.allHeaderFields) {
    id value = httpResponse.allHeaderFields[key];
    std::string name = NsToUtf8([key description]);
    std::string headerValue = NsToUtf8([value description]);
    std::string lower = ToLowerStr(name);

    if (lower == "content-length" || lower == "transfer-encoding" || lower == "content-encoding" ||
        lower == "connection" || lower == "keep-alive" || lower == "upgrade") {
      continue;
    }
    // The shell UI is trusted and intentionally served over loopback; a CSP
    // bound to the upstream origin would block the streaming server requests.
    if (lower.rfind("content-security-policy", 0) == 0) continue;

    if (lower == "location") headerValue = RewriteToLocal(headerValue);
    if (lower == "set-cookie") {
      // Cookies are relayed for the loopback origin only.
      size_t domain = ToLowerStr(headerValue).find("; domain=");
      if (domain != std::string::npos) {
        size_t end = headerValue.find(';', domain + 1);
        headerValue = headerValue.substr(0, domain) +
                      (end == std::string::npos ? "" : headerValue.substr(end));
      }
    }
    response.headers.emplace_back(name, headerValue);
  }

  if (responseData) {
    response.body.assign((const char *)responseData.bytes, (size_t)responseData.length);
  }
  response.noBody = request.method == "HEAD" || response.status == 204 || response.status == 304;
  return response;
}

void SendResponse(int fd, const HttpResponse &response) {
  std::ostringstream head;
  head << "HTTP/1.1 " << response.status << " "
       << (response.status == 200 ? "OK" : response.reason) << "\r\n";
  bool hasContentType = false;
  for (const auto &[name, value] : response.headers) {
    if (ToLowerStr(name) == "content-type") hasContentType = true;
    head << name << ": " << value << "\r\n";
  }
  if (!hasContentType) head << "Content-Type: text/html; charset=utf-8\r\n";
  head << "Content-Length: " << (response.noBody ? 0 : response.body.size()) << "\r\n";
  head << "Connection: close\r\n\r\n";

  std::string headStr = head.str();
  if (!SendAll(fd, headStr.data(), headStr.size())) return;
  if (!response.noBody && !response.body.empty()) {
    SendAll(fd, response.body.data(), response.body.size());
  }
}

void HandleConnection(int fd) {
  struct timeval timeout{5, 0};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
  int one = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

  HttpRequest request;
  if (ReadRequest(fd, request)) {
    HttpResponse response = ForwardRequest(request);
    SendResponse(fd, response);
  }
  ::close(fd);
}

void AcceptLoop() {
  while (g_running.load()) {
    int client = ::accept(g_listenFd, nullptr, nullptr);
    if (client < 0) {
      if (g_running.load()) std::this_thread::sleep_for(std::chrono::milliseconds(50));
      continue;
    }
    std::thread(HandleConnection, client).detach();
  }
}

} // namespace

std::string StartLocalUiProxy(const std::string &upstreamBaseUrl) {
  if (g_running.load()) {
    return LocalUiProxyBaseUrl();
  }
  if (upstreamBaseUrl.rfind("http://", 0) != 0 && upstreamBaseUrl.rfind("https://", 0) != 0) {
    return {};
  }

  std::string upstream = upstreamBaseUrl;
  while (!upstream.empty() && upstream.back() == '/') upstream.pop_back();

  int listenFd = ::socket(AF_INET, SOCK_STREAM, 0);
  if (listenFd < 0) {
    AppendToCrashLog("[PROXY]: socket() failed");
    return {};
  }

  int one = 1;
  setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = 0; // ephemeral port
  if (::bind(listenFd, (sockaddr *)&addr, sizeof(addr)) != 0 ||
      ::listen(listenFd, 64) != 0) {
    AppendToCrashLog("[PROXY]: bind/listen failed");
    ::close(listenFd);
    return {};
  }

  socklen_t addrLen = sizeof(addr);
  if (::getsockname(listenFd, (sockaddr *)&addr, &addrLen) != 0) {
    AppendToCrashLog("[PROXY]: getsockname failed");
    ::close(listenFd);
    return {};
  }

  {
    std::lock_guard<std::mutex> lock(g_upstreamMutex);
    g_upstreamBase = upstream;
    g_port = ntohs(addr.sin_port);
    g_localBase = "http://127.0.0.1:" + std::to_string(g_port);
  }
  g_listenFd = listenFd;
  g_running = true;
  g_acceptThread = std::thread(AcceptLoop);

  std::cout << "[PROXY]: Serving " << upstream << " on " << LocalUiProxyBaseUrl() << std::endl;
  return LocalUiProxyBaseUrl();
}

void StopLocalUiProxy() {
  if (!g_running.exchange(false)) return;
  if (g_listenFd >= 0) {
    ::shutdown(g_listenFd, SHUT_RDWR);
    ::close(g_listenFd);
    g_listenFd = -1;
  }
  if (g_acceptThread.joinable()) g_acceptThread.join();
  std::lock_guard<std::mutex> lock(g_upstreamMutex);
  g_upstreamBase.clear();
  g_localBase.clear();
}

std::string LocalUiProxyBaseUrl() {
  std::lock_guard<std::mutex> lock(g_upstreamMutex);
  return g_localBase;
}
