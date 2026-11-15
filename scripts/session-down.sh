#!/bin/bash
# session-down.sh — stop the VRCFT relay (and its gvproxy forward). The Spout bridge lives inside the
# launcher process, so it goes away only when the launcher is quit; this script never kills the VM.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
if pgrep -f vrcft_bridge.py >/dev/null; then
  pkill -TERM -f vrcft_bridge.py
  sleep 1
  echo "vrcft relay stopped (forward removed by its SIGTERM handler)"
else
  echo "vrcft relay not running"
fi
pgrep -f vrcft_bridge.py >/dev/null && { pkill -9 -f vrcft_bridge.py; echo "force-killed"; }
rm -f /tmp/vrcft-bridge.pid
