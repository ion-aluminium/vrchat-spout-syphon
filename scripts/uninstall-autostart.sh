#!/bin/bash
# uninstall-autostart.sh — stop injecting the bridge and remove the login agent.
set -uo pipefail
PLIST="$HOME/Library/LaunchAgents/local.vrcspout.bridge.plist"
launchctl bootout "gui/$(id -u)/local.vrcspout.bridge" 2>/dev/null || true
rm -f "$PLIST"
launchctl unsetenv DYLD_INSERT_LIBRARIES
launchctl unsetenv SPOUTSYPHON_ENABLE
launchctl unsetenv SPOUTSYPHON_LOG
launchctl unsetenv SPOUTSYPHON_NAME
echo "autostart removed; the launcher now needs scripts/launch-with-bridge.sh to get the bridge"
