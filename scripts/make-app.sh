#!/bin/bash
# make-app.sh — build "FX Steam Launcher (Spout).app", a drop-in launcher that always starts FX with the
# Spout bridge injected (and just brings it to the front when it is already running with the bridge).
#
#   scripts/make-app.sh          # builds build/FX Steam Launcher (Spout).app
#   scripts/make-app.sh --install   # also copies it to ~/Applications
#
# Put it in the Dock in place of the original icon. macOS refuses DYLD_* through launchctl setenv, so a
# wrapper is the only way to make injection automatic without modifying the signed launcher.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT=$PWD
NAME="FX Steam Launcher (Spout)"
APP="build/$NAME.app"
ORIG="/Applications/FX Steam Launcher.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cat > "$APP/Contents/MacOS/launcher" <<LAUNCH
#!/bin/bash
# Start FX with the Spout bridge; if it is already running, just bring it to the front.
LOG=/tmp/vrcspout-wrapper.log
DYLIB="\$HOME/Library/Application Support/VRCSpoutBridge/libSpoutSyphon.dylib"
ORIG="/Applications/FX Steam Launcher.app"
echo "\$(date '+%F %T') wrapper start" >>"\$LOG"
PID=\$(pgrep -f "FX Steam Launcher.app/Contents/MacOS/steamac-vm" | head -1)
if [ -n "\$PID" ]; then
  if vmmap "\$PID" 2>/dev/null | grep -q libSpoutSyphon; then
    echo "already running with the bridge -> activating" >>"\$LOG"
    open -a "\$ORIG"
    exit 0
  fi
  echo "running WITHOUT the bridge -> restarting it injected" >>"\$LOG"
  osascript -e 'tell application id "es.fxgam.steamac" to quit' >/dev/null 2>&1
  for i in \$(seq 1 30); do pgrep -f "FX Steam Launcher.app/Contents/MacOS/steamac-vm" >/dev/null || break; sleep 1; done
  pkill -f "FX Steam Launcher[.]app/Contents/MacOS/steamac-vm" 2>/dev/null
  sleep 1
fi
mkdir -p "\$HOME/Library/Application Support/VRCSpoutBridge"
if [ -f "$ROOT/build/libSpoutSyphon.dylib" ]; then
  cp -f "$ROOT/build/libSpoutSyphon.dylib" "\$DYLIB"
fi
if [ ! -f "\$DYLIB" ]; then
  echo "missing \$DYLIB -> launch without the bridge" >>"\$LOG"
  open -a "\$ORIG"
  exit 1
fi
echo "exec with bridge" >>"\$LOG"
export DYLD_INSERT_LIBRARIES="\$DYLIB"
export SPOUTSYPHON_ENABLE=1
export SPOUTSYPHON_NAME="VRChat Spout Camera"
export SPOUTSYPHON_LOG=/tmp/spoutsyphon.log
exec "\$ORIG/Contents/MacOS/steamac-vm"
LAUNCH
chmod +x "$APP/Contents/MacOS/launcher"

# borrow the original icon so it looks identical in the Dock
if [ -f "$ORIG/Contents/Resources/AppIcon.icns" ]; then
  cp "$ORIG/Contents/Resources/AppIcon.icns" "$APP/Contents/Resources/"
  ICON='<key>CFBundleIconFile</key><string>AppIcon</string>'
else
  ICON=''
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.vrcspout.fxlauncher</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>launcher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><false/>
  $ICON
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" 2>/dev/null || true
echo "built: $APP"

if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/$NAME.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "installed: $HOME/Applications/$NAME.app"
  echo "drag that onto the Dock in place of the original FX icon"
fi
