#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/build_app.sh" >/dev/null
swift build -c release --product IPTimeDaemon >/dev/null

BIN_DIR="$(swift build -c release --show-bin-path)"
ARCH="$(uname -m)"
DIST_DIR="$ROOT/.build/dist/IPTime-macos-$ARCH"
ZIP_PATH="$ROOT/.build/IPTime-macos-$ARCH.zip"

rm -rf "$DIST_DIR" "$ZIP_PATH"
mkdir -p "$DIST_DIR"

cp -R "$ROOT/.build/IP Time.app" "$DIST_DIR/IP Time.app"
cp "$BIN_DIR/IPTimeDaemon" "$DIST_DIR/iptime-daemon"
cp "$ROOT/scripts/uninstall.sh" "$DIST_DIR/uninstall.sh"

cat > "$DIST_DIR/install_prebuilt.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="IP Time.app"
APP_SOURCE="$ROOT/$APP_NAME"
APP_DEST="/Applications/$APP_NAME"
DAEMON_SOURCE="$ROOT/iptime-daemon"
DAEMON_DEST="/usr/local/libexec/iptime-daemon"
SUPPORT_DIR="/Library/Application Support/IPTime"
PLIST="/Library/LaunchDaemons/local.iptime.daemon.plist"
LABEL="local.iptime.daemon"
AGENT_LABEL="local.iptime.menubar"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

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
    <key>ProgramArguments</key>
    <array>
        <string>$APP_DEST/Contents/MacOS/DualTimeMenuBar</string>
    </array>
    <key>RunAtLoad</key>
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
SCRIPT

chmod +x "$DIST_DIR/install_prebuilt.sh" "$DIST_DIR/uninstall.sh"

(cd "$ROOT/.build/dist" && /usr/bin/zip -qry "$ZIP_PATH" "IPTime-macos-$ARCH")
echo "$ZIP_PATH"
