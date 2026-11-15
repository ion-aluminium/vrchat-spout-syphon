#!/bin/bash
# webcam-up.sh — feed the Mac camera into VRChat's "Camera Tracking" (Selfie Expression).
#
# How it works: a DirectShow virtual camera (UnityCaptureFilter64.dll) is registered in the VRChat Wine
# prefix, so VRChat lists "Unity Video Capture" as a webcam. This script supplies it with frames:
#
#   Mac camera --AVFoundation--> cam_send --TCP 127.0.0.1:9123--> gvproxy forward --> guest
#       --> unitycam_feed.exe --shared memory--> UnityCapture filter --> VRChat
#
#   scripts/webcam-up.sh [--device N] [--fps N] [--port N]
#   scripts/webcam-up.sh --list        # cameras the Mac exposes
#   scripts/webcam-down.sh             # stop both ends
#
# Needs Camera permission for the host app (System Settings > Privacy & Security > Camera).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PORT=${WEBCAM_PORT:-9123}
DEVICE=${WEBCAM_DEVICE:-1}      # 0 = capture card, 1 = MacBook Pro Camera on this machine
FPS=${WEBCAM_FPS:-15}
LOG=${WEBCAM_LOG:-/tmp/webcam-feed.log}

while [ $# -gt 0 ]; do
  case "$1" in
    --list) ./build/cam_send --list; exit 0 ;;
    --device) DEVICE=$2; shift 2 ;;
    --fps) FPS=$2; shift 2 ;;
    --port) PORT=$2; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -x build/cam_send ] || { echo "build first: scripts/build.sh" >&2; exit 1; }
[ -f build/unitycam_feed.exe ] || { echo "build the guest feeder: see docs/VRCFT.md" >&2; exit 1; }

echo "== gvproxy forward"
S=$(ls -t /tmp/steamac-*/api.sock 2>/dev/null | head -1)
[ -n "${S:-}" ] || { echo "launcher not running" >&2; exit 1; }
curl -sS -o /dev/null -X POST --unix-socket "$S" -H 'Content-Type: application/json' \
  -d "{\"local\":\"127.0.0.1:$PORT\",\"remote\":\"192.168.127.2:$PORT\",\"protocol\":\"tcp\"}" \
  http://localhost/services/forwarder/expose
echo "   127.0.0.1:$PORT -> guest $PORT"

echo "== guest feeder"
./scripts/guest-ssh.sh 'mkdir -p /home/steamos/webcam' >/dev/null 2>&1
./scripts/guest-push.sh build/unitycam_feed.exe /home/steamos/webcam/unitycam_feed.exe >/dev/null || {
  echo "could not copy unitycam_feed.exe into the guest" >&2; exit 1; }
./scripts/guest-ssh.sh "pkill -f '[u]nitycam_feed.exe' 2>/dev/null; cd /home/steamos/webcam && setsid nohup ../vrcprobe/run-probe.sh unitycam_feed.exe --port $PORT > /home/steamos/webcam/feed.log 2>&1 < /dev/null & sleep 2; tail -2 /home/steamos/webcam/feed.log" </dev/null 2>&1 | tail -3

echo "== Mac camera"
pkill -f 'build/cam_send' 2>/dev/null
: >"$LOG"
nohup ./build/cam_send --port "$PORT" --device "$DEVICE" --fps "$FPS" >>"$LOG" 2>&1 &
sleep 4
sed 's/^/   /' "$LOG" | head -6
echo
echo "VRChat: Settings > Tracking & IK > Camera Tracking > Current Webcam Device = 'Unity Video Capture',"
echo "        Enable Selfie Expression on. Logs: $LOG and the guest's ~/webcam/feed.log"
