# Stremio for macOS

A native macOS build of the community Stremio v5 shell. The Windows build talks
to WebView2; this one talks to WKWebView and AppKit. The web UI, the shell
protocol, the settings file and the mpv setup are the same, so add-ons,
playback, subtitles, torrents and Discord presence behave like they do on
Windows.

Both targets live in the same tree. CMake builds the macOS app on Apple
hardware and the Windows app everywhere else.

## How it works

- **UI** — WKWebView with the same injected JavaScript the Windows build uses.
  The part that fakes `window.qt.webChannelTransport` on WebView2 is replaced by
  a shim over `WKScriptMessageHandler`; the handshake, events and mpv commands
  above it are untouched.
- **Video** — libmpv with the render API, drawing into a `CAOpenGLLayer` behind
  the transparent web view. The official Stremio shell does the same on macOS,
  and hardware decoding goes through VideoToolbox.
- **Shell** — AppKit window, status bar item, menus, single instance handling,
  update checks, and the streaming server as a child process.

Two details are macOS-only and worth knowing if you touch the code:

**The UI is served through a loopback proxy.** WKWebView refuses requests to
`http://127.0.0.1` from an https page. Chromium doesn't, which is why the
Windows build gets away with loading the UI from a remote origin. Since the UI
has to reach the streaming server on port 11470, the app serves the UI from
`http://127.0.0.1:<random port>` and forwards the requests. The page origin is
then http, and the streaming server is reachable.

**Local files are passed to the UI as `file://` URLs.** The UI decodes the
stream URL into an absolute URL, and a plain path fails there, so playback
never starts. Everything else about drag and drop, Open With and magnet links
is unchanged.

## Install

Grab the DMG from the releases page, open it and drag Stremio onto
Applications. Node, ffmpeg and ffprobe are bundled, so there is nothing else to
install.

### First launch

The build is ad-hoc signed, not notarized, so macOS will show something like
*"Apple could not verify Stremio is free of malware"* the first time you open
it. That's Gatekeeper reacting to the missing notarization ticket, not an actual
warning about the app.

To get past it: click **Done** on the dialog, open **System Settings → Privacy &
Security**, scroll to the Security section, click **Open Anyway** next to the
Stremio entry, and confirm. From then on it launches like any other app. On
older macOS versions, right-clicking the app and choosing Open also works.

If you'd rather avoid the click, the equivalent command is:

```sh
xattr -dr com.apple.quarantine /Applications/Stremio.app
```

A Developer ID certificate plus notarization is what removes this step for
everyone; that needs a paid Apple Developer account, so it's not set up here.

Requirements: macOS 13 or newer, Apple Silicon. Building from source on Intel
works the same way if you have an x86_64 libmpv.

## Build

```sh
brew install cmake pkgconf mpv node
cmake -S . -B build-macos -DCMAKE_BUILD_TYPE=Release
cmake --build build-macos -j8
open build-macos/src/macos/Stremio.app
```

`brew install mpv` matters because Homebrew builds it with libmpv, which is
what the renderer links against. If pkg-config can't find it, add
`$(brew --prefix mpv)/lib/pkgconfig` to `PKG_CONFIG_PATH`.

The default build keeps `DEBUG_LOG=ON`: devtools are enabled and the page
console is forwarded to the app log. `-DDEBUG_LOG=OFF` is the release setup.

## Packaging

```sh
node build/deploy_macos.js --dmg --pkg --zip --install
```

That builds Release, downloads `server.js`, bundles a self-contained Node
(the official nodejs.org build, or whatever `STREMIO_NODE_PATH` points at),
makes ffmpeg and ffprobe relocatable with dylibbundler when it's installed,
seeds the default settings, signs the bundle ad-hoc and writes the artifacts
into `dist/mac`. `--install` also copies the app into `/Applications` and
registers the URL schemes with LaunchServices.

## Configuration

`portable_config` works the same way as on Windows. It's resolved in this
order:

1. `--portable-config=<path>`
2. `$STREMIO_PORTABLE_CONFIG`
3. `portable_config` next to `Stremio.app`
4. `~/Library/Application Support/Stremio/portable_config` (the default)

The directory is handed to mpv as `config-dir`, so `mpv.conf`, `input.conf`,
`scripts/` and `shaders/` (Anime4K and friends) work as expected. `webmods/`
and `extensions/` are read from the same place. `stremio-settings.ini` keeps
the Windows keys: `[General]`, `[MPV]`, `[Window]` and the mpv command and
property allow-lists under `[Security]`.

## Tests

```sh
ctest --test-dir build-macos --output-on-failure
```

- `unit_tests` — INI handling, string helpers, the webmods injectors, SHA-256,
  the real signed update manifest (valid, tampered and garbage), settings
  merging and window placement.
- `selftest_protocol` — runs the app in `--self-test` mode. A bundled harness
  page drives the real JS bridge and mpv: handshake, loadfile, duration, pause,
  volume, subtitle drop, allow-list blocking. Native checks cover the renderer,
  tray, PiP, always-on-top, dark theme, page zoom and the splash.
- `live_webui` — runs the real web UI: handshake, proxy, streaming server,
  single instance forwarding, local file playback with decoded frames, the
  updater, and a clean SIGTERM shutdown.
- `endpoints_reachable` — checks that a web UI endpoint answers.

The last two need a graphical session. `live_webui` skips playback when ffmpeg
is missing.

## Diagnostics

| Flag or variable | What it does |
| --- | --- |
| `--webui-url=<url>` | Use another web UI (it gets proxied too) |
| `--no-ui-proxy` | Load the UI directly; the streaming server will be blocked by WKWebView |
| `--streaming-server-disabled` | Don't start `server.js` |
| `--self-test --selftest-media=<file>` | Protocol end-to-end harness |
| `--check-endpoints` | Print the first reachable UI endpoint |
| `--capture-window=<png> --capture-after=<s>` | Capture the app's own window (no screen recording permission needed; OpenGL layers aren't included) |
| `STREMIO_CAPTURE_SNAPSHOT=<png>` | WKWebView snapshot, shows UI transparency through the alpha channel |

Crashes and `[SECURITY]`, `[UPDATER]`, `[PROTOCOL]` and `[NODE]` messages go to
`errors-<day>.<month>.<year>.txt` in `portable_config`, same as Windows.

## Known limits

- **Browser extensions** load through `WKWebExtensionController` (macOS 15.4+)
  and only support Safari-compatible APIs. Chrome-only extensions won't work.
  Failures are logged, and the PremID/Stylus flows only work when their
  extension actually loaded.
- **HDR** isn't wired up. The render path outputs SDR; mpv can do EDR but that
  needs work on the layer.
- **Full auto-updates** need macOS artifacts in the signed
  `version-details.json`, which upstream doesn't publish. Partial updates of
  `server.js` do work.
- **The community web UI is required.** The official `app.strem.io` shell
  speaks a newer protocol (server-address events) and isn't supported, same as
  the Windows build.
