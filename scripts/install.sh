#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="IP Time.app"
APP_SOURCE="$ROOT/.build/$APP_NAME"
APP_DEST="/Applications/$APP_NAME"
DAEMON_DEST="/usr/local/libexec/iptime-daemon"
SUPPORT_DIR="/Library/Application Support/IPTime"
PLIST="/Library/LaunchDaemons/local.iptime.daemon.plist"
LABEL="local.iptime.daemon"
AGENT_LABEL="local.iptime.menubar"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

if ! command -v swift >/dev/null 2>&1; then
    echo "Swift toolchain is required. Install Xcode Command Line Tools first:"
    echo "xcode-select --install"
    exit 1
fi

"$ROOT/scripts/build_app.sh" >/dev/null
swift build -c release --product IPTimeDaemon >/dev/null

BIN_DIR="$(swift build -c release --show-bin-path)"
DAEMON_SOURCE="$BIN_DIR/IPTimeDaemon"

sudo install -d -o root -g wheel -m 755 /usr/local/libexec
sudo install -d -o root -g wheel -m 755 "$SUPPORT_DIR"
sudo install -o root -g wheel -m 755 "$DAEMON_SOURCE" "$DAEMON_DEST"

sudo rm -rf "$APP_DEST"
sudo cp -R "$APP_SOURCE" "$APP_DEST"
sudo chown -R root:wheel "$APP_DEST"

TMP_PLIST="$(mktemp)"
cat > "$TMP_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DAEMON_DEST</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/Library/Logs/IPTimeDaemon.out.log</string>
    <key>StandardErrorPath</key>
    <string>/Library/Logs/IPTimeDaemon.err.log</string>
</dict>
</plist>
PLIST

sudo cp "$TMP_PLIST" "$PLIST"
rm -f "$TMP_PLIST"
sudo chown root:wheel "$PLIST"
sudo chmod 644 "$PLIST"

sudo launchctl bootout system "$PLIST" >/dev/null 2>&1 || true
sudo launchctl bootstrap system "$PLIST"
sudo launchctl enable "system/$LABEL"
sudo launchctl kickstart -k "system/$LABEL"

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$AGENT_LABEL</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>IPTIME_LAUNCH_AGENT</key>
        <string>1</string>
    </dict>
    <key>ProgramArguments</key>
    <array>
        <string>$APP_DEST/Contents/MacOS/DualTimeMenuBar</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/IPTimeMenuBar.out.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/IPTimeMenuBar.err.log</string>
</dict>
</plist>
PLIST
chmod 644 "$AGENT_PLIST"

open "$APP_DEST"

echo "Installed $APP_DEST"
echo "Installed LaunchDaemon $LABEL"
echo "Installed LaunchAgent $AGENT_LABEL"
echo "Status file: $SUPPORT_DIR/status.json"
