#!/bin/bash
# build.sh — reproducible build of libSpoutSyphon.dylib and the test tools.
#
# Requirements: macOS on Apple silicon, Xcode command line tools (clang), and OBS installed at
# /Applications/OBS.app (we link its bundled, version-matched Syphon.framework — OBS 33 ships
# Syphon 5; the headers in vendor/syphon/Headers come from Syphon-Framework f476167).
#
# Output: build/libSpoutSyphon.dylib, build/hosttest, build/syphon_test_send, build/syphon_test_recv
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
OBS=${OBS_APP:-/Applications/OBS.app}
SYPHON="$OBS/Contents/Frameworks"
[ -d "$SYPHON/Syphon.framework" ] || { echo "build: no Syphon.framework in $OBS" >&2; exit 1; }
mkdir -p build
CFLAGS="-fobjc-arc -g -O2 -Ivendor/include -F$SYPHON"
LIBS="-framework Syphon -framework Metal -framework Foundation -Wl,-rpath,$SYPHON"

echo "== libSpoutSyphon.dylib"
clang -dynamiclib $CFLAGS -o build/libSpoutSyphon.dylib src/spoutsyphon.m $LIBS

echo "== hosttest (dylib test host)"
clang -fobjc-arc -g -O1 -o build/hosttest src/hosttest.m -framework Foundation -framework Metal

echo "== syphon_test_send / syphon_test_recv (stage-D isolation tools)"
clang $CFLAGS -o build/syphon_test_send src/syphon_test_send.m $LIBS
clang $CFLAGS -o build/syphon_test_recv src/syphon_test_recv.m $LIBS

echo "== ok"
ls -l build/
