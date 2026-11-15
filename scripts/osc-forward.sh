#!/bin/bash
# osc-forward.sh — expose the guest's VRChat OSC ports to the Mac through gvproxy's forwarder API.
#
# The VM is behind user-mode NAT (guest 192.168.127.2), so the host cannot send UDP to it directly.
# gvproxy (started by the launcher) has an HTTP API on /tmp/steamac-<pid>/api.sock that can add TCP/UDP
# forwards. This script adds 127.0.0.1:9000 -> guest:9000 (VRChat's OSC *input*), loopback only.
#
#   scripts/osc-forward.sh add      # idempotent
#   scripts/osc-forward.sh remove
#   scripts/osc-forward.sh list     # every forward the VM currently has
set -uo pipefail
API=$(ls -t /tmp/steamac-*/api.sock 2>/dev/null | head -1)
if [ -z "${API:-}" ]; then echo "no gvproxy api.sock — is the launcher running?" >&2; exit 1; fi
LOCAL=${LOCAL_PORT:-9000}
REMOTE=${REMOTE_PORT:-9000}
CMD=${1:-list}

case "$CMD" in
  list)
    curl -sS --unix-socket "$API" http://localhost/services/forwarder/all |
      python3 -c "import json,sys; [print(f\"{f['protocol']:4} {f['local']:22} -> {f['remote']}\") for f in json.load(sys.stdin)]"
    ;;
  add)
    code=$(curl -sS -o /tmp/osc-forward.out -w '%{http_code}' -X POST --unix-socket "$API" \
      -H 'Content-Type: application/json' \
      -d "{\"local\":\"127.0.0.1:$LOCAL\",\"remote\":\"192.168.127.2:$REMOTE\",\"protocol\":\"udp\"}" \
      http://localhost/services/forwarder/expose)
    if [ "$code" = "200" ] || [ "$code" = "201" ]; then
      echo "forward added: udp 127.0.0.1:$LOCAL -> guest 192.168.127.2:$REMOTE"
    elif [ "$code" = "400" ] || [ "$code" = "500" ]; then
      # gvproxy answers 400/500 when the same local address is already exposed
      echo "forward already present (or refused: $(cat /tmp/osc-forward.out))"
    else
      echo "unexpected response $code: $(cat /tmp/osc-forward.out)" >&2; exit 1
    fi
    ;;
  remove)
    curl -sS -X POST --unix-socket "$API" -H 'Content-Type: application/json' \
      -d "{\"local\":\"127.0.0.1:$LOCAL\",\"remote\":\"192.168.127.2:$REMOTE\",\"protocol\":\"udp\"}" \
      http://localhost/services/forwarder/unexpose >/dev/null 2>&1
    echo "forward removed: udp 127.0.0.1:$LOCAL"
    ;;
  *)
    echo "usage: $0 [add|remove|list]" >&2; exit 2 ;;
esac
