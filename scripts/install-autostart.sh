#!/bin/bash
# install-autostart.sh — make the Spout bridge + face-tracking relay start with the session.
#
#   scripts/install-autostart.sh      # install and activate now
#   scripts/uninstall-autostart.sh    # remove
#
# What it does:
#   * copies libSpoutSyphon.dylib to ~/Library/Application Support/VRCSpoutBridge (stable path)
#   * sets DYLD_INSERT_LIBRARIES / SPOUTSYPHON_* session-wide via launchctl, so a normal Dock or
#     Finder launch of FX Steam Launcher is injected too (the dylib exits immediately in any other app)
#   * installs ~/Library/LaunchAgents/local.vrcspout.bridge.plist to re-apply that at login and to
#     start the VRCFT OSC relay
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT=$PWD
PLIST="$HOME/Library/LaunchAgents/local.vrcspout.bridge.plist"
mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.vrcspout.bridge</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$ROOT/scripts/autostart.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>/tmp/vrcspout-autostart.log</string>
  <key>StandardErrorPath</key><string>/tmp/vrcspout-autostart.log</string>
</dict>
</plist>
PLISTEOF

launchctl bootout "gui/$(id -u)/local.vrcspout.bridge" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load -w "$PLIST"
sleep 1
bash "$ROOT/scripts/autostart.sh"
echo "installed: $PLIST"
launchctl getenv DYLD_INSERT_LIBRARIES | sed 's/^/  DYLD_INSERT_LIBRARIES=/'
