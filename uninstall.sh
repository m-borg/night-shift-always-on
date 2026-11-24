#!/usr/bin/env bash
set -euo pipefail

LABEL="com.local.nightshift-always-on"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
INSTALL_APP_PATH="$HOME/Applications/NightShiftAlwaysOn.app"
CLI_LINK="$HOME/.local/bin/nightshift-always-on"
UID_NUM="$(id -u)"

launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
pkill -x NightShiftAlwaysOn 2>/dev/null || true
rm -f "$PLIST_PATH" "$CLI_LINK"
rm -rf "$INSTALL_APP_PATH"
defaults delete "$LABEL" 2>/dev/null || true

echo "Uninstalled NightShiftAlwaysOn."
