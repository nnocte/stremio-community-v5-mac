# Stremio Desktop — macOS port

Native macOS build of the community Stremio shell. The Windows build (WebView2 +
Win32) is untouched; macOS uses WKWebView + AppKit and the same shell protocol,
settings format and web UI, so add-ons and the player behave identically.

```
┌──────────────────────────────────────────────┐
│ NSWindow                                      │
│  ├─ MPVVideoView   (libmpv render API, OpenGL)│  ← video
│  ├─ WKWebView      (transparent background)   │  ← web UI + controls
│  └─ SplashView     (until app-ready)          │
└──────────────────────────────────────────────┘
```

| Concern | Windows | macOS |
| --- | --- | --- |
| Web view | WebView2 (Chromium) | WKWebView |
| Shell JS bridge | `window.chrome.webview` | same API, implemented over `WKScriptMessageHandler` |
| Video output | libmpv `wid` window embedding | libmpv render API (`vo=libmpv`) + `CAOpenGLLayer` |
| Tray | Win32 `NOTIFYICONDATA` | `NSStatusItem` |
| Streaming server | `stremio-runtime.exe` + `server.js` | `stremio-runtime`/`node` + `server.js` (posix_spawn, own process group) |
| Settings | `portable_config/stremio-settings.ini` | identical file, same keys |
| Update signature | OpenSSL RSA/SHA-256 | Security.framework RSA/SHA-256 |
| Media keys | `RegisterHotKey(VK_MEDIA_PLAY_PAUSE)` | `MPRemoteCommandCenter` + Now Playing |
| Discord RPC | discord-rpc library | built-in IPC client (`$TMPDIR/discord-ipc-*`) |

The web UI and protocol are the same as the Windows build: the shell JS shim,
the Qt-style transport handshake, the `mpv-command`/`mpv-set-prop` allow-lists,
`seek-hover`/`seek-leave` (ThumbFast), PiP events, `app-ready`, Discord activity
payloads and the `portable_config` layout are all byte-compatible.

## Two macOS-specific behaviours

**1. The web UI is served through a loopback proxy.** WKWebView blocks requests
to `http://127.0.0.1` from an https page (mixed content), while Chromium-based
shells allow it. The UI must reach the streaming server on
`http://127.0.0.1:11470`, so the app starts a small reverse proxy and loads the
UI from `http://127.0.0.1:<random port>`. The page origin is then http and the
streaming server requests are same-scheme. The proxy forwards to whichever UI
endpoint is reachable (see `--webui-url=`). Disable with `--no-ui-proxy` when
debugging.

**2. Local files are passed to the UI as `file://` URLs.** The web UI's
`decodeStream()` deserializes the stream URL into an absolute URL; a bare
path fails to decode and playback never starts. Drag & drop, `open with` and
magnet/torrent handling are unchanged otherwise.

## Requirements

- macOS 13 or newer (Apple Silicon or Intel)
- Xcode command line tools (`xcode-select --install`)
- CMake 3.16+, `pkg-config` (`brew install cmake pkgconf`)
- libmpv with the render API: `brew install mpv` (Homebrew builds with
  `-Dlibmpv=true`)
- `node` for the streaming server (`brew install node`), or bundle
  `stremio-runtime` from the official Stremio app

## Build & run

```bash
cmake -S . -B build-macos -DCMAKE_BUILD_TYPE=Release
cmake --build build-macos -j8

open build-macos/src/macos/Stremio.app          # normal run
build-macos/src/macos/Stremio.app/Contents/MacOS/Stremio   # console logs
```

`DEBUG_LOG=ON` (default) enables devtools, page console forwarding to the app
log and the periodic page-state diagnostics. `-DDEBUG_LOG=OFF` produces the
release configuration used by the deploy script.

## Deploy

```bash
node build/deploy_macos.js --zip
```

Builds the bundle, downloads `server.js`, stages `node`/`ffmpeg` next to the
executable (official shell layout), copies the default settings template,
ad-hoc signs the app and writes `dist/mac/Stremio-<version>.zip`.

## portable_config

Same file names and semantics as Windows. Resolution order:

1. `--portable-config=<path>`
2. `$STREMIO_PORTABLE_CONFIG`
3. `portable_config` next to `Stremio.app` (truly portable)
4. `~/Library/Application Support/Stremio/portable_config` (default)

The directory is the mpv `config-dir`, so `mpv.conf`, `input.conf`, `scripts/`,
`shaders/` (Anime4K etc.) work exactly like on Windows. `webmods/` (CSS/JS
injection) and `extensions/` are read from the same place. `stremio-settings.ini`
uses the same `[General]`, `[MPV]`, `[Window]` and `[Security]` sections,
including the mpv command/property allow-lists.

## Tests

```bash
ctest --test-dir build-macos --output-on-failure
```

| Test | Covers |
| --- | --- |
| `unit_tests` | INI round-trips/comments, string + webmods injectors, SHA-256, the real signed update manifest (positive + tampered + garbage), settings allow-list merging, window placement |
| `selftest_protocol` | The app in `--self-test` mode: bundled harness page drives the real JS bridge and mpv (loadfile, duration, pause, volume, subtitle drop, allow-list blocking) and native checks for the renderer, tray, PiP, always-on-top, dark theme, page zoom and splash |
| `live_webui` | The real web UI: handshake, loopback proxy, streaming server readiness, single-instance forwarding, local-file playback (`loadfile file://…` + decoded frames), updater, clean SIGTERM shutdown |
| `endpoints_reachable` | Web UI endpoint reachability (`--check-endpoints`) |

`selftest_protocol` and `live_webui` need a graphical session; `live_webui`
skips the playback phase when `ffmpeg` is unavailable.

## Diagnostics

| Flag / env | Purpose |
| --- | --- |
| `--webui-url=<url>` | Override the web UI (also proxied) |
| `--no-ui-proxy` | Load the UI directly (mixed content will break the streaming server) |
| `--streaming-server-disabled` | Do not start `server.js` |
| `--self-test --selftest-media=<file>` | Protocol end-to-end harness |
| `--check-endpoints` | Print the first reachable web UI endpoint |
| `--capture-window=<png> --capture-after=<s>` | Capture the app window (own window, no screen-recording permission). OpenGL layers are not part of the capture. |
| `STREMIO_CAPTURE_SNAPSHOT=<png>` | WKWebView snapshot (shows UI transparency via alpha) |
| `--autoupdater-endpoint=`, `--autoupdater-force-full` | Updater overrides |

`errors-<d>.<m>.<year>.txt` in `portable_config` holds crash logs and the
`[SECURITY]`/`[UPDATER]`/`[PROTOCOL]`/`[NODE]` messages, same as Windows.

## Known differences from the Windows build

- **Browser extensions**: WKWebView supports Safari-style web extensions
  (`WKWebExtensionController`, macOS 15.4+). Directories in
  `portable_config/extensions` are loaded on a best-effort basis; Chrome-only
  APIs are not available and failures are logged. PremID/Stylus flows are
  implemented but only work when the extension loaded.
- **Updater**: `server.js` partial updates work (downloaded into
  `portable_config`, checksum-verified). Full updates require macOS artifacts in
  the signed `version-details.json`; until they exist the updater logs and skips
  the prompt.
- **HDR**: the render API path is SDR. HDR passthrough depends on mpv's EDR
  support and is not implemented in this port.
- **Window state** is stored in the same `[Window]` section but uses Cocoa
  coordinates.
- The `--webui-url=` override targets the community shell UI. The official
  `app.strem.io` shell UI speaks a newer protocol (server-address events) and is
  not supported — same limitation as the Windows build.
