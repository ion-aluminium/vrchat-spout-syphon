#!/bin/bash
# autostart.sh — run at login (LaunchAgent): make every launcher start inject the Spout bridge, and keep
# the VRCFT OSC relay running.
#
# The dylib lives in ~/Library/Application Support/VRCSpoutBridge so that moving the project does not
# leave a dangling DYLD_INSERT_LIBRARIES path (a missing library would stop other apps from launching).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$HOME/Library/Application Support/VRCSpoutBridge"
DYLIB="$DEST/libSpoutSyphon.dylib"

mkdir -p "$DEST"
if [ -f "$ROOT/build/libSpoutSyphon.dylib" ]; then
  cp -f "$ROOT/build/libSpoutSyphon.dylib" "$DYLIB"
fi
# Note: macOS ignores launchctl setenv for DYLD_* variables, so the bridge cannot be injected
# session-wide. Use the wrapper app (scripts/make-app.sh) or scripts/launch-with-bridge.sh instead;
# this agent only keeps the dylib copy fresh and the face-tracking relay running.

# face tracking relay (Windows VRCFaceTracking -> guest VRChat)
if ! pgrep -f vrcft_bridge.py >/dev/null; then
  cd "$ROOT" || exit 0
  nohup ./src/vrcft/vrcft_bridge.py --listen 0.0.0.0:9000 --http 0.0.0.0:19090 \
    >>/tmp/vrcft-bridge.log 2>&1 &
fi
