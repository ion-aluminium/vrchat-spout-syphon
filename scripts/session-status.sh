#!/bin/bash
# session-status.sh — one view of both halves: Spout (OBS) and VRCFT (face tracking).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
QUERY_PORT=${QUERY_PORT:-19090}

echo "== spout (VRChat camera -> Syphon -> OBS)"
running=$(pgrep -f "FX Steam Launcher.app/Contents/MacOS/steamac-vm" | head -1 || true)
if [ -z "$running" ]; then
  echo "   launcher not running"
else
  injected=$(vmmap "$running" 2>/dev/null | grep -c SpoutSyphon || true)
  echo "   launcher pid $running, bridge injected: $([ "$injected" -gt 0 ] && echo yes || echo NO)"
fi
servers=$(./build/syphon_list --wait 1 2>/dev/null | tail -n +2)
if [ -n "$servers" ]; then
  echo "$servers" | while IFS=$'\t' read -r name app uuid; do echo "   syphon: $name  app=$app"; done
  if [ -f /tmp/spoutsyphon.log ]; then
    tail -n 1 /tmp/spoutsyphon.log | sed 's/^/   /'
  fi
else
  echo "   no Syphon server (OBS source will be black)"
fi

echo "== vrcft (Windows VRCFaceTracking -> VRChat in the guest)"
if ! pgrep -f vrcft_bridge.py >/dev/null; then
  echo "   relay not running — scripts/session-up.sh --no-spout"
else
  echo "   relay pid $(pgrep -f vrcft_bridge.py | head -1)"
  curl -fsS --max-time 3 "http://127.0.0.1:$QUERY_PORT/status" 2>/dev/null | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print('   status endpoint unavailable'); raise SystemExit
print(f\"   osc in: {d.get('osc_packets',0)} packets ({d.get('osc_packets_per_sec',0):.0f}/s) last {d.get('osc_last_peer')} {d.get('osc_last_address')}\")
print(f\"   lan {d.get('listen')} -> {d.get('relay')} | oscquery upstream port {d.get('query_upstream_port')} | avatar {d.get('avatar')}\")
" || echo "   status endpoint unavailable"
fi

curl -fsS --max-time 4 "http://127.0.0.1:$QUERY_PORT/" 2>/dev/null | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print('   VRChat OSCQuery not reachable through the relay'); raise SystemExit
want={'/avatar/avatarfullfacetracking':'avatar full FT',
      '/avatar/parameters/UserFaceTracking':'tracking source',
      '/avatar/parameters/UserEyeTracking':'eye tracking'}
def w(n,p=''):
    for k,v in n.get('CONTENTS',{}).items():
        q=p+'/'+k
        if q in want:
            val=v.get('VALUE'); print(f'   {want[q]:14} {val[0] if isinstance(val,list) and val else val}')
        w(v,q)
w(d)
" || echo "   VRChat OSCQuery not reachable through the relay"
