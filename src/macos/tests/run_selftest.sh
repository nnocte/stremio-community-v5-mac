#!/bin/bash
# Runs the app in --self-test mode with a freshly generated media file.
#
# Usage: run_selftest.sh <path-to-app-binary> <build-dir>
set -u

APP="$1"
BUILD_DIR="$2"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/stremio-selftest.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

MEDIA="$WORK_DIR/test.mp4"
if command -v ffmpeg >/dev/null 2>&1; then
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i testsrc=duration=6:size=320x240:rate=15 \
    -f lavfi -i sine=frequency=440:duration=6 \
    -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$MEDIA" >/dev/null 2>&1
else
  echo "SKIP: ffmpeg not available"
  exit 77
fi

if [ ! -s "$MEDIA" ]; then
  echo "SKIP: could not generate test media"
  exit 77
fi

CONFIG_DIR="$WORK_DIR/portable_config"
mkdir -p "$CONFIG_DIR"

LOG_FILE="$WORK_DIR/selftest.log"
"$APP" --self-test \
       --streaming-server-disabled \
       --portable-config="$CONFIG_DIR" \
       --selftest-media="$MEDIA" \
       --selftest-timeout=120 >"$LOG_FILE" 2>&1
STATUS=$?

cat "$LOG_FILE"

if [ $STATUS -eq 0 ] && grep -q "SELFTEST_PASS" "$LOG_FILE"; then
  echo "selftest: PASS"
  exit 0
fi

echo "selftest: FAIL (exit $STATUS)"
exit 1
