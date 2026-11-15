#!/bin/bash
# webcam-down.sh — stop the Mac sender and the guest feeder, and drop the gvproxy forward.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PORT=${WEBCAM_PORT:-9123}
pkill -f 'build/cam_send' && echo "cam_send stopped" || echo "cam_send not running"
./scripts/guest-ssh.sh "pkill -f '[u]nitycam_feed.exe' && echo 'guest feeder stopped' || echo 'guest feeder not running'" </dev/null 2>&1 | tail -1
S=$(ls -t /tmp/steamac-*/api.sock 2>/dev/null | head -1)
[ -n "${S:-}" ] && curl -sS -o /dev/null -X POST --unix-socket "$S" -H 'Content-Type: application/json' \
  -d "{\"local\":\"127.0.0.1:$PORT\",\"remote\":\"192.168.127.2:$PORT\",\"protocol\":\"tcp\"}" \
  http://localhost/services/forwarder/unexpose 2>/dev/null
echo "forward 127.0.0.1:$PORT removed"
