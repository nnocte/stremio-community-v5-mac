#ifndef NODESERVER_H
#define NODESERVER_H

// Streaming server process (Windows: stremio-runtime.exe + server.js launched
// with CreateProcess + a kill-on-close job object; macOS: posix_spawn in its
// own process group).
bool StartNodeServer();
void StopNodeServer();

#endif // NODESERVER_H
