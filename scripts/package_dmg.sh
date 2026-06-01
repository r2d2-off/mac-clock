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

echo "Uninstalling IP Time..."
echo "You may be asked for your macOS administrator password."

killall DualTimeMenuBar >/dev/null 2>&1 || true
sudo launchctl bootout system "$PLIST" >/dev/null 2>&1 || true
sudo rm -f "$PLIST"
sudo rm -f "$DAEMON_DEST"
sudo rm -rf "$APP_DEST"

echo
echo "Uninstalled IP Time."
echo "Status file kept at: $SUPPORT_DIR/status.json"

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
  /Library/Application Support/IPTime/status.json

After installation, add /Applications/IP Time.app to Login Items if you want
the menu bar item to appear automatically after reboot.
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
