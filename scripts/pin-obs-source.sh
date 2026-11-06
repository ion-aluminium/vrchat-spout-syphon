#!/bin/bash
# pin-obs-source.sh — point the OBS Syphon source at the running bridge's server (name/app/uuid), then
# restart OBS so it reloads the scene collection. OBS must be closed while its JSON is edited.
#
# Run this if the OBS source shows a black frame because the Syphon app/server names do not match, or
# after a launcher rename. Normal use does not need it: OBS matches by name+app and survives VM restarts.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
line=$(./build/syphon_list --wait 2 | sed -n 2p)
name=$(printf '%s' "$line" | cut -f1)
app=$(printf '%s' "$line" | cut -f2)
uuid=$(printf '%s' "$line" | cut -f3)
if [ -z "${name:-}" ]; then echo "no Syphon server is running — start the bridge and turn VRChat's Spout Stream on first" >&2; exit 1; fi
echo "server: name='$name' app='$app' uuid='$uuid'"

was_running=0
pgrep -f "/Applications/OBS.app/Contents/MacOS/OBS" >/dev/null && was_running=1
if [ "$was_running" = 1 ]; then
  osascript -e 'tell application id "com.obsproject.obs-studio" to quit' >/dev/null 2>&1
  for i in $(seq 1 20); do pgrep -f "/Applications/OBS.app/Contents/MacOS/OBS" >/dev/null || break; sleep 1; done
  pgrep -f "/Applications/OBS.app/Contents/MacOS/OBS" >/dev/null && { echo "OBS did not quit" >&2; exit 1; }
fi
SPOUTSYPHON_NAME="$name" SPOUTSYPHON_APP="$app" SPOUTSYPHON_UUID="$uuid" python3 scripts/obs-add-syphon-source.py
[ "$was_running" = 1 ] && { open -a /Applications/OBS.app; echo "OBS restarted"; }
