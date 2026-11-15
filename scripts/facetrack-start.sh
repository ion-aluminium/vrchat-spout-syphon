#!/bin/bash
# facetrack-start.sh — run the Live Link Face -> VRChat face-tracking bridge on the Mac.
#
#   1. ensures a loopback-only UDP forward 127.0.0.1:9000 -> guest 192.168.127.2:9000 (gvproxy API)
#   2. starts src/facetrack/facetrack.py bound to the Mac's LAN IP (where the iPhone sends) on 11111
#
#   scripts/facetrack-start.sh            # start in the background
#   scripts/facetrack-start.sh --fg       # run in the foreground (Ctrl-C to stop)
#   scripts/facetrack-stop.sh             # stop
#
# VRChat must have OSC enabled (Action Menu -> Options -> OSC) and an avatar with Face Tracking.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
LOG=${FACETRACK_LOG:-/tmp/facetrack.log}
PORT=${FACETRACK_PORT:-11111}
LIMIT=${FACETRACK_OSC:-127.0.0.1:9000}

# prefer the LAN address so the phone can reach us; fall back to all interfaces
LAN=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
BIND=${FACETRACK_BIND:-${LAN:-0.0.0.0}:$PORT}

echo "== osc forward"
LOCAL_PORT=9000 REMOTE_PORT=9000 scripts/osc-forward.sh add

if pgrep -f "facetrack.py" >/dev/null; then
  echo "facetrack already running (pid $(pgrep -f facetrack.py | head -1))"
  exit 0
fi

mkdir -p logs
if [ "${1:-}" = "--fg" ]; then
  exec ./src/facetrack/facetrack.py --listen "$BIND" --osc "$LIMIT"
else
  : >"$LOG"
  nohup ./src/facetrack/facetrack.py --listen "$BIND" --osc "$LIMIT" >"$LOG" 2>&1 &
  sleep 1
  echo "== facetrack"
  head -2 "$LOG"
  echo
  echo "Live Link Face: set the target to $BIND (UDP)."
  echo "VRChat: OSC on, avatar with Face Tracking + 'Use All Tracking Keys'."
  echo "Log: $LOG    Stop: scripts/facetrack-stop.sh"
fi
