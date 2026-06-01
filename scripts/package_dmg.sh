#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/package_pkg.sh" >/dev/null

ARCH="$(uname -m)"
DMG_ROOT="$ROOT/.build/dmg/IP Time"
DMG_PATH="$ROOT/.build/IPTime-macos-$ARCH.dmg"
PKG_PATH="$ROOT/.build/IPTime-macos-$ARCH.pkg"

rm -rf "$ROOT/.build/dmg" "$DMG_PATH"
mkdir -p "$DMG_ROOT"

cp "$PKG_PATH" "$DMG_ROOT/IP Time.pkg"

cat > "$DMG_ROOT/Uninstall.command" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

APP_DEST="/Applications/IP Time.app"
DAEMON_DEST="/usr/local/libexec/iptime-daemon"
SUPPORT_DIR="/Library/Application Support/IPTime"
PLIST="/Library/LaunchDaemons/local.iptime.daemon.plist"
AGENT_LABEL="local.iptime.menubar"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
USER_SUPPORT_DIR="$HOME/Library/Application Support/IPTime"
SYSTEM_LOGS=(
    "/Library/Logs/IPTimeDaemon.out.log"
    "/Library/Logs/IPTimeDaemon.err.log"
    "/Library/Logs/IPTimeInstaller.log"
)
USER_LOGS=(
    "$HOME/Library/Logs/IPTimeMenuBar.out.log"
    "$HOME/Library/Logs/IPTimeMenuBar.err.log"
)
SYSTEM_RESTORE_SCRIPT="$SUPPORT_DIR/restore-system-preferences.sh"
USER_RESTORE_SCRIPT="$USER_SUPPORT_DIR/restore-user-preferences.sh"

echo "Uninstalling IP Time..."
echo "You may be asked for your macOS administrator password."

killall DualTimeMenuBar >/dev/null 2>&1 || true
launchctl bootout "gui/$(id -u)" "$AGENT_PLIST" >/dev/null 2>&1 || true
sudo launchctl bootout system "$PLIST" >/dev/null 2>&1 || true

if [ -f "$USER_RESTORE_SCRIPT" ]; then
    /bin/sh "$USER_RESTORE_SCRIPT" || true
fi

if [ -f "$SYSTEM_RESTORE_SCRIPT" ]; then
    sudo /bin/sh "$SYSTEM_RESTORE_SCRIPT" || true
fi

rm -f "$AGENT_PLIST"
sudo rm -f "$PLIST"
sudo rm -f "$DAEMON_DEST"
sudo rm -rf "$APP_DEST"
sudo rm -rf "$SUPPORT_DIR"
rm -rf "$USER_SUPPORT_DIR"
sudo rm -f "${SYSTEM_LOGS[@]}"
rm -f "${USER_LOGS[@]}"

echo
echo "Uninstalled IP Time."
echo "Restored saved preferences and removed status/config/backup/log files."

if [ -t 0 ]; then
    echo
    read -r -p "Press Return to close this window..."
fi
SCRIPT

cat > "$DMG_ROOT/README.txt" <<'TEXT'
IP Time

Install:
  Double-click IP Time.pkg

Uninstall:
  Double-click Uninstall.command

Installed files:
  /Applications/IP Time.app
  /usr/local/libexec/iptime-daemon
  /Library/LaunchDaemons/local.iptime.daemon.plist
  ~/Library/LaunchAgents/local.iptime.menubar.plist
  /Library/Application Support/IPTime
  ~/Library/Application Support/IPTime

After installation, the menu bar item starts automatically at login.
TEXT

chmod +x "$DMG_ROOT/Uninstall.command"

hdiutil create \
    -volname "IP Time" \
    -srcfolder "$DMG_ROOT" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null

hdiutil verify "$DMG_PATH" >/dev/null
echo "$DMG_PATH"
