#!/bin/bash
# launch-with-bridge.sh — start FX Steam Launcher with libSpoutSyphon.dylib injected, so that a guest
# D3D11 Spout shared texture becomes a macOS Syphon source (readable by OBS's mac-syphon source).
#
# Nothing on disk is modified: the .app is untouched, the guest is untouched, and the injection lasts
# only for this launch. `scripts/rollback.sh` (or a normal launch from Finder) restores stock behaviour.
#
#   scripts/launch-with-bridge.sh [--name NAME] [--fps N] [--width W --height H] [--flip] [--yes]
#
# --yes quits a running launcher without asking (VRChat will close with it).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT=$PWD
APP=${FX_APP:-/Applications/FX Steam Launcher.app}
BUNDLE_ID=es.fxgam.steamac
DYLIB="$ROOT/build/libSpoutSyphon.dylib"
LOG=${SPOUTSYPHON_LOG:-/tmp/spoutsyphon.log}
NAME=${SPOUTSYPHON_NAME:-VRChat Spout Camera}
FPS=${SPOUTSYPHON_FPS:-30}
W=${SPOUTSYPHON_WIDTH:-0}
H=${SPOUTSYPHON_HEIGHT:-0}
FLIP=${SPOUTSYPHON_FLIP:-1}
YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME=$2; shift 2 ;;
    --fps) FPS=$2; shift 2 ;;
    --width) W=$2; shift 2 ;;
    --height) H=$2; shift 2 ;;
    --flip) FLIP=1; shift ;;
    --yes) YES=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -f "$DYLIB" ] || { echo "missing $DYLIB — run scripts/build.sh first" >&2; exit 1; }
[ -d "$APP" ] || { echo "not found: $APP" >&2; exit 1; }

running=$(pgrep -f "FX Steam Launcher.app/Contents/MacOS/steamac-vm" | head -1 || true)
if [ -n "$running" ]; then
  echo "FX Steam Launcher is running (pid $running). The bridge must be injected at process start,"
  echo "so the launcher has to be restarted. VRChat and the SteamOS session will close."
  if [ "$YES" -ne 1 ]; then
    read -r -p "Quit it now and relaunch with the bridge? [y/N] " a
    case "$a" in y|Y|yes|YES) ;; *) echo "aborted"; exit 1 ;; esac
  fi
  osascript -e 'tell application id "es.fxgam.steamac" to quit' >/dev/null 2>&1
  for i in $(seq 1 30); do
    pgrep -f "FX Steam Launcher.app/Contents/MacOS/steamac-vm" >/dev/null || break
    sleep 1
  done
  if pgrep -f "FX Steam Launcher.app/Contents/MacOS/steamac-vm" >/dev/null; then
    echo "launcher did not quit after 30 s; quit it manually (Cmd+Q) and re-run" >&2
    exit 1
  fi
  echo "launcher closed"
fi

: >"$LOG"
echo "starting $APP with the Spout→Syphon bridge"
echo "  syphon name : $NAME"
echo "  publish rate: $FPS fps"
[ "$W" != 0 ] && echo "  size filter : ${W}x${H:-?}"
echo "  log         : $LOG"

open -a "$APP" \
  --env "DYLD_INSERT_LIBRARIES=$DYLIB" \
  --env "SPOUTSYPHON_ENABLE=1" \
  --env "SPOUTSYPHON_NAME=$NAME" \
  --env "SPOUTSYPHON_FPS=$FPS" \
  --env "SPOUTSYPHON_WIDTH=$W" \
  --env "SPOUTSYPHON_HEIGHT=$H" \
  --env "SPOUTSYPHON_FLIP=$FLIP" \
  --env "SPOUTSYPHON_LOG=$LOG" || { echo "open failed" >&2; exit 1; }

for i in $(seq 1 20); do
  grep -q "loaded in pid" "$LOG" 2>/dev/null && break
  sleep 0.5
done
if grep -q "loaded in pid" "$LOG" 2>/dev/null; then
  echo
  echo "bridge injected:"
  sed -n '1,4p' "$LOG"
  echo
  echo "In VRChat: open the Camera (Stream mode) and turn on 'Spout Stream'. This script's log then"
  echo "shows a 'newSharedTexture ... ACCEPTED' line and a Syphon server named \"$NAME\" appears in OBS."
else
  echo "warning: the dylib did not report in; see $LOG and logs/" >&2
  exit 1
fi
