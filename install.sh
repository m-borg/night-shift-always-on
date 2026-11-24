#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="NightShiftAlwaysOn.app"
INSTALL_APP_DIR="$HOME/Applications"
INSTALL_APP_PATH="$INSTALL_APP_DIR/$APP_NAME"
EXEC_PATH="$INSTALL_APP_PATH/Contents/MacOS/NightShiftAlwaysOn"
LABEL="com.local.nightshift-always-on"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$LAUNCH_AGENTS_DIR/$LABEL.plist"
CLI_BIN_DIR="$HOME/.local/bin"
CLI_LINK="$CLI_BIN_DIR/nightshift-always-on"
UID_NUM="$(id -u)"

"$ROOT_DIR/build.sh"

# Stop existing agent if running
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
pkill -x NightShiftAlwaysOn 2>/dev/null || true
sleep 0.3

# Install app bundle to ~/Applications
mkdir -p "$INSTALL_APP_DIR"
rm -rf "$INSTALL_APP_PATH"
cp -R "$ROOT_DIR/build/$APP_NAME" "$INSTALL_APP_PATH"

# Install LaunchAgent plist
mkdir -p "$LAUNCH_AGENTS_DIR"
cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${EXEC_PATH}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
EOF

# Install convenient CLI symlink
mkdir -p "$CLI_BIN_DIR"
ln -sf "$EXEC_PATH" "$CLI_LINK"

# Start the LaunchAgent
launchctl bootstrap "gui/$UID_NUM" "$PLIST_PATH"
launchctl kickstart -k "gui/$UID_NUM/$LABEL" 2>/dev/null || true

echo ""
echo "Installed and started!"
echo "  App:         $INSTALL_APP_PATH"
echo "  LaunchAgent: $PLIST_PATH"
echo "  CLI:         $CLI_LINK"
