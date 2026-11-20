#!/bin/sh
# Build Wisp (Debug) and relaunch it. Usage: tools/run_app.sh [--fresh]  (--fresh resets TCC + settings)
set -e
cd "$(dirname "$0")/../app"
xcodegen generate -q >/dev/null
LOG=$(mktemp)
if ! xcodebuild -project Wisp.xcodeproj -scheme Wisp -configuration Debug -derivedDataPath ../build/DerivedData \
  -destination 'platform=macOS,arch=arm64' build >"$LOG" 2>&1; then
  grep -E "error:" "$LOG" | head -20; echo "BUILD FAILED (full log: $LOG)"; exit 1
fi
echo "BUILD SUCCEEDED"
pkill -x Wisp 2>/dev/null || true
sleep 0.5
if [ "$1" = "--fresh" ]; then
  tccutil reset All com.zakvirani.wisp >/dev/null
  defaults delete com.zakvirani.wisp 2>/dev/null || true
  rm -rf "$HOME/Library/Application Support/Wisp/settings.json"
fi
open ../build/DerivedData/Build/Products/Debug/Wisp.app
