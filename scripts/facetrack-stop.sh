#!/bin/bash
# facetrack-stop.sh — stop the face-tracking bridge and drop the OSC forward.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
pkill -f "facetrack.py" && echo "facetrack stopped" || echo "facetrack not running"
scripts/osc-forward.sh remove 2>/dev/null || true
