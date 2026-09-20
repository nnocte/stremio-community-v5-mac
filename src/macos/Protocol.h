#ifndef PROTOCOL_H
#define PROTOCOL_H

// Single instance handling + protocol argument forwarding. The Windows build
// uses a named mutex plus WM_COPYDATA; macOS uses an flock'd lock file and a
// unix domain socket in the portable_config directory.
//
// Returns false when another instance is already running (arguments were
// forwarded to it and the caller must exit).
bool AcquireSingleInstance(int argc, char *argv[]);
void ReleaseSingleInstance();

#endif // PROTOCOL_H
