#!/bin/bash
# facetrack-status.sh — one-shot status of the Live Link Face -> VRChat chain.
#
# Reports the iPhone target address, whether the bridge is running, and what VRChat itself says about
# the current avatar (queried through OSCQuery inside the guest, so no extra port is exposed).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "== bridge"
if pgrep -f facetrack.py >/dev/null; then
  echo "  running (pid $(pgrep -f facetrack.py | head -1))"
  lsof -nP -iUDP:${FACETRACK_PORT:-11111} 2>/dev/null | tail -1 | awk '{print "  listening:", $9}'
  tail -n 2 /tmp/facetrack.log 2>/dev/null | sed 's/^/  /'
else
  echo "  not running — scripts/facetrack-start.sh"
fi

echo "== iphone target"
LAN=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "?")
echo "  Live Link Face -> $LAN:${FACETRACK_PORT:-11111} (UDP, ARKit mode)"

echo "== osc forward"
scripts/osc-forward.sh list 2>/dev/null | grep -E "9000" | sed 's/^/  /' || echo "  missing — scripts/osc-forward.sh add"

echo "== VRChat (via OSCQuery, from inside the guest)"
./scripts/guest-ssh.sh 'python3 - <<"PY"
import json,urllib.request
try:
    d=json.load(urllib.request.urlopen("http://127.0.0.1:40331/", timeout=4))
except Exception as e:
    print("  OSCQuery unavailable:", e); raise SystemExit
want={"/avatar/avatarfullfacetracking":"avatar supports native face tracking",
      "/avatar/parameters/UserFaceTracking":"tracking source active",
      "/avatar/parameters/UserEyeTracking":"eye tracking active"}
def walk(node, path=""):
    for k,v in node.get("CONTENTS",{}).items():
        p=path+"/"+k
        if p in want:
            val=v.get("VALUE")
            print(f"  {want[p]:38} {p} = {val[0] if isinstance(val,list) and val else val}")
        walk(v,p)
walk(d)
PY' </dev/null 2>/dev/null | tail -6
