#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export COPYFILE_DISABLE=1

"$ROOT/scripts/package_release.sh" >/dev/null

ARCH="$(uname -m)"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
DIST_DIR="$ROOT/.build/dist/IPTime-macos-$ARCH"
PKG_WORK="$ROOT/.build/pkg"
PAYLOAD="$PKG_WORK/payload"
SCRIPTS_DIR="$PKG_WORK/scripts"
PKG_PATH="$ROOT/.build/IPTime-macos-$ARCH.pkg"
PLIST_PATH="$PAYLOAD/Library/LaunchDaemons/local.iptime.daemon.plist"

rm -rf "$PKG_WORK" "$PKG_PATH"
mkdir -p \
    "$PAYLOAD/Applications" \
    "$PAYLOAD/usr/local/libexec" \
    "$PAYLOAD/Library/LaunchDaemons" \
    "$PAYLOAD/Library/Application Support/IPTime" \
    "$SCRIPTS_DIR"

cp -R "$DIST_DIR/IP Time.app" "$PAYLOAD/Applications/IP Time.app"
cp "$DIST_DIR/iptime-daemon" "$PAYLOAD/usr/local/libexec/iptime-daemon"
chmod 755 "$PAYLOAD/usr/local/libexec/iptime-daemon"

cat > "$PLIST_PATH" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>local.iptime.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/libexec/iptime-daemon</string>
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
chmod 644 "$PLIST_PATH"

cat > "$SCRIPTS_DIR/preinstall" <<'SCRIPT'
#!/bin/sh
set +e

LOG="/Library/Logs/IPTimeInstaller.log"
/bin/mkdir -p /Library/Logs
exec >> "$LOG" 2>&1
echo "[$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')] preinstall start"

LABEL="local.iptime.daemon"
PLIST="/Library/LaunchDaemons/local.iptime.daemon.plist"

/usr/bin/killall DualTimeMenuBar >/dev/null 2>&1 || true
/bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
/bin/launchctl bootout system "$PLIST" >/dev/null 2>&1 || true

echo "[$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')] preinstall done"
exit 0
SCRIPT

cat > "$SCRIPTS_DIR/postinstall" <<'SCRIPT'
#!/bin/sh
set +e

LOG="/Library/Logs/IPTimeInstaller.log"
/bin/mkdir -p /Library/Logs
exec >> "$LOG" 2>&1
echo "[$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')] postinstall start"

APP_DEST="/Applications/IP Time.app"
DAEMON_DEST="/usr/local/libexec/iptime-daemon"
SUPPORT_DIR="/Library/Application Support/IPTime"
PLIST="/Library/LaunchDaemons/local.iptime.daemon.plist"
LABEL="local.iptime.daemon"

/usr/sbin/chown -R root:wheel "$APP_DEST" || true
/usr/sbin/chown root:wheel "$DAEMON_DEST" "$PLIST" || true
/bin/chmod 755 "$DAEMON_DEST" || true
/bin/chmod 644 "$PLIST" || true
/bin/mkdir -p "$SUPPORT_DIR" || true
/usr/sbin/chown root:wheel "$SUPPORT_DIR" || true
/bin/chmod 755 "$SUPPORT_DIR" || true

/bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
/bin/launchctl bootout system "$PLIST" >/dev/null 2>&1 || true
/bin/launchctl bootstrap system "$PLIST" || true
/bin/launchctl enable "system/$LABEL" >/dev/null 2>&1 || true
/bin/launchctl kickstart -k "system/$LABEL" >/dev/null 2>&1 || true

CONSOLE_USER="$(/usr/bin/stat -f %Su /dev/console 2>/dev/null || true)"
if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
    CONSOLE_UID="$(/usr/bin/id -u "$CONSOLE_USER" 2>/dev/null || true)"
    if [ -n "$CONSOLE_UID" ]; then
        /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" /usr/bin/defaults write NSGlobalDomain AppleLanguages -array "en-US" >/dev/null 2>&1 || true
        /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" /usr/bin/open "$APP_DEST" >/dev/null 2>&1 || true
    fi
fi

echo "[$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')] postinstall done"
exit 0
SCRIPT

chmod +x "$SCRIPTS_DIR/preinstall" "$SCRIPTS_DIR/postinstall"

find "$PAYLOAD" -name '._*' -delete
xattr -cr "$PAYLOAD" >/dev/null 2>&1 || true
find "$SCRIPTS_DIR" -name '._*' -delete
xattr -cr "$SCRIPTS_DIR" >/dev/null 2>&1 || true

pkgbuild \
    --root "$PAYLOAD" \
    --scripts "$SCRIPTS_DIR" \
    --identifier "local.iptime" \
    --version "$VERSION" \
    --install-location "/" \
    --ownership recommended \
    "$PKG_PATH" >/dev/null

echo "$PKG_PATH"
