#!/bin/bash
# status.sh — one-shot state check for the bridge, used during validation and by the user.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
LOG=${SPOUTSYPHON_LOG:-/tmp/spoutsyphon.log}

echo "== launcher / VM =="
pgrep -lf "FX Steam Launcher.app/Contents/MacOS/steamac-vm" || echo "  launcher not running"
echo "  dylib loaded in:"
for p in $(pgrep -f "steamac-vm"); do
  if vmmap "$p" 2>/dev/null | grep -q libSpoutSyphon; then echo "    pid $p: libSpoutSyphon present"; fi
done
echo
echo "== bridge log ($LOG) =="
if [ -f "$LOG" ]; then tail -n "${1:-12}" "$LOG"; else echo "  (absent)"; fi
echo
echo "== syphon servers visible to a client =="
./build/syphon_test_recv --seconds 2 2>&1 | grep -E "attached|server\(s\)|frame " | head -12
