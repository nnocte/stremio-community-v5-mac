#!/bin/bash
# Live verification against the real web UI: startup, transport handshake,
# single-instance forwarding, local-file playback through mpv, the streaming
# server, the update check and clean shutdown.
#
# Usage: live_webui_test.sh <path-to-app-binary> [work-dir]
set -u

APP="$1"
WORK_DIR="${2:-$(mktemp -d "${TMPDIR:-/tmp}/stremio-live.XXXXXX")}"
mkdir -p "$WORK_DIR"
CONFIG_DIR="$WORK_DIR/portable_config"
LOG_FILE="$WORK_DIR/live.log"
mkdir -p "$CONFIG_DIR"

echo "workdir: $WORK_DIR"

# The streaming server script is required for local file playback; stage a copy
# like the deploy script does (skipped when the app bundles one already).
if [ ! -f "$CONFIG_DIR/server.js" ]; then
  curl -sL --max-time 120 "https://dl.strem.io/server/v4.20.15/desktop/server.js" \
    -o "$CONFIG_DIR/server.js" || true
fi

MEDIA="$WORK_DIR/test.mp4"
if command -v ffmpeg >/dev/null 2>&1; then
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i testsrc=duration=90:size=640x360:rate=15 \
    -f lavfi -i sine=frequency=440:duration=90 \
    -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$MEDIA" >/dev/null 2>&1
fi

"$APP" --portable-config="$CONFIG_DIR" >"$LOG_FILE" 2>&1 &
APP_PID=$!

fail() {
  echo "live: FAIL - $1"
  tail -40 "$LOG_FILE"
  kill -9 "$APP_PID" 2>/dev/null
  exit 1
}

# Wait up to 90s for the web UI handshake.
for i in $(seq 1 90); do
  if grep -q "Web UI reported app-ready" "$LOG_FILE"; then break; fi
  if ! kill -0 "$APP_PID" 2>/dev/null; then fail "app exited during startup"; fi
  sleep 1
done
grep -q "Web UI reported app-ready" "$LOG_FILE" || fail "web UI never reported app-ready"
grep -q "Navigation complete" "$LOG_FILE" || fail "no navigation completed"
grep -q "mpv render context created" "$LOG_FILE" || fail "mpv render context was not created"
grep -q "streaming server is ready" "$LOG_FILE" || fail "streaming server did not become ready"
grep -q "PROXY" "$LOG_FILE" || fail "loopback UI proxy was not started"

# Single instance: a second launch with a protocol argument must forward and exit.
SECOND_LOG="$WORK_DIR/second.log"
"$APP" --portable-config="$CONFIG_DIR" "stremio://detail/movie/tt0111161" >"$SECOND_LOG" 2>&1
SECOND_STATUS=$?
if [ $SECOND_STATUS -ne 0 ]; then fail "second instance exited with $SECOND_STATUS"; fi
if ! grep -q "forwarding arguments" "$SECOND_LOG"; then fail "second instance did not forward"; fi
sleep 2
grep -q "Received argument stremio://detail/movie/tt0111161" "$LOG_FILE" ||
  fail "first instance did not receive the forwarded argument"

# Local file playback through the real web UI: forward a media path and expect
# the UI to hand it to mpv (as a file:// URL) and mpv to decode frames.
if [ -s "$MEDIA" ]; then
  "$APP" --portable-config="$CONFIG_DIR" "$MEDIA" >"$WORK_DIR/third.log" 2>&1
  # mpv only plays the file when the web UI accepted the OpenFile event and
  # forwarded it as a loadfile command; AV progress lines are emitted by mpv
  # itself in both debug and release builds.
  for i in $(seq 1 60); do
    grep -q "AV: 00:00:0" "$LOG_FILE" && break
    sleep 1
  done
  grep -q "Received argument $MEDIA" "$LOG_FILE" || fail "media argument was not forwarded"
  grep -q "AV: 00:00:0" "$LOG_FILE" || fail "mpv did not decode any frames"
  if grep -q "loadfile" "$LOG_FILE"; then
    grep -q "file://" "$LOG_FILE" || fail "local file was not sent as a file:// URL"
  fi
else
  echo "live: skipping playback check (ffmpeg not available)"
fi

# Update check runs in the background; give it time.
for i in $(seq 1 30); do
  grep -q "Update check done" "$LOG_FILE" && break
  sleep 1
done
grep -q "Update check done" "$LOG_FILE" || fail "updater did not finish"
if grep -q "Signature verification failed" "$LOG_FILE"; then fail "update signature failed"; fi

# Quit cleanly via SIGTERM (the app routes it through NSApplication terminate).
kill -TERM "$APP_PID" 2>/dev/null
for i in $(seq 1 30); do
  kill -0 "$APP_PID" 2>/dev/null || break
  sleep 0.5
done
if kill -0 "$APP_PID" 2>/dev/null; then
  kill -9 "$APP_PID"
  pkill -f "$CONFIG_DIR/server.js" 2>/dev/null
  fail "app did not quit on SIGTERM"
fi
grep -q "Exiting..." "$LOG_FILE" || fail "cleanup did not run"
if pgrep -f "$CONFIG_DIR/server.js" >/dev/null 2>&1; then
  pkill -f "$CONFIG_DIR/server.js"
  fail "streaming server was not stopped on shutdown"
fi

echo "live: PASS"
echo "log: $LOG_FILE"
exit 0
