#!/bin/bash
# session-up.sh — bring up the whole VRChat-in-a-VM session for the Mac side:
#
#   * FX Steam Launcher with libSpoutSyphon injected  (VRChat's Spout camera -> Syphon -> OBS)
#   * the VRCFaceTracking OSC relay                   (Windows VRCFT -> VRChat in the guest)
#
# The two are independent: Spout is a GPU path (no ports), VRCFT is OSC over UDP. This script only
# coordinates their lifecycle so one command gives you both.
#
#   scripts/session-up.sh                 # start what is missing, do not disturb a running VRChat
#   scripts/session-up.sh --restart-vm    # restart the launcher (closes VRChat) to inject Spout
#   scripts/session-up.sh --no-spout      # VRCFT relay only
#   scripts/session-up.sh --no-vrcft      # Spout bridge only
#   scripts/session-up.sh --takeover      # stop a leftover ad-hoc relay that holds the OSC port
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT=$PWD
OSC_PORT=${OSC_PORT:-9000}
QUERY_PORT=${QUERY_PORT:-19090}
LOG=${VRCFT_LOG:-/tmp/vrcft-bridge.log}
WANT_SPOUT=1
WANT_VRCFT=1
RESTART=0
TAKEOVER=0

while [ $# -gt 0 ]; do
  case "$1" in
    --restart-vm) RESTART=1; shift ;;
    --no-spout) WANT_SPOUT=0; shift ;;
    --no-vrcft) WANT_VRCFT=0; shift ;;
    --takeover) TAKEOVER=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

LAN=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "")

echo "== Spout bridge"
if [ "$WANT_SPOUT" = 1 ]; then
  running=$(pgrep -f "FX Steam Launcher.app/Contents/MacOS/steamac-vm" | head -1 || true)
  injected=0
  if [ -n "$running" ]; then
    injected=$(vmmap "$running" 2>/dev/null | grep -c SpoutSyphon || true)
  fi
  if [ "$injected" -gt 0 ] && [ "$RESTART" = 0 ]; then
    echo "   already injected (pid $running)"
  elif [ -z "$running" ]; then
    echo "   starting the launcher with the bridge"
    scripts/launch-with-bridge.sh --yes 2>&1 | sed 's/^/   /'
  elif [ "$RESTART" = 1 ]; then
    echo "   restarting the launcher with the bridge (VRChat will close)"
    scripts/launch-with-bridge.sh --yes 2>&1 | sed 's/^/   /'
  else
    echo "   launcher is running WITHOUT the bridge -> OBS will stay black."
    echo "   add --restart-vm to restart it with the bridge (closes VRChat)."
  fi
else
  echo "   skipped (--no-spout)"
fi

echo "== VRCFT relay"
if [ "$WANT_VRCFT" = 1 ]; then
  if pgrep -f "vrcft_bridge.py" >/dev/null; then
    echo "   already running (pid $(pgrep -f vrcft_bridge.py | head -1))"
  else
    holder=$(lsof -nP -iUDP:$OSC_PORT 2>/dev/null | awk 'NR>1 {print $1" "pid "$2; exit}')
    if [ -n "${holder:-}" ]; then
      if [ "$TAKEOVER" = 1 ]; then
        echo "   stopping the process holding UDP $OSC_PORT: $holder"
        pkill -f "vrcft-bridge/mac-bridge.py" 2>/dev/null
        pid=$(echo "$holder" | awk '{print $3}')
        [ -n "$pid" ] && kill "$pid" 2>/dev/null
        sleep 1
      else
        echo "   UDP $OSC_PORT is already taken by: $holder"
        echo "   if that is the old ad-hoc relay, re-run with --takeover"
        exit 1
      fi
    fi
    : >"$LOG"
    BIND=${VRCFT_BIND:-${LAN:-0.0.0.0}:$OSC_PORT}
    nohup ./src/vrcft/vrcft_bridge.py --listen "$BIND" --http "0.0.0.0:$QUERY_PORT" \
      ${VRCFT_ALLOW:+--allow "$VRCFT_ALLOW"} >>"$LOG" 2>&1 &
    sleep 1.5
    sed -n '1,4p' "$LOG" | sed 's/^/   /'
  fi
else
  echo "   skipped (--no-vrcft)"
fi

echo
echo "== status"
scripts/session-status.sh 2>/dev/null | sed 's/^/   /'

cat <<EOF

Next:
  Windows PC : powershell -ExecutionPolicy Bypass -File windows-vrcft-bridge.ps1 -MacIP ${LAN:-<mac-ip>}
               (VRCFT keeps OSC at 127.0.0.1:9000; Live Link Face targets that PC)
  OBS        : Syphon Client source "VRChat Spout Camera"
  VRChat     : Camera -> Stream -> Spout Stream on; OSC on; VRCFT avatar
EOF
