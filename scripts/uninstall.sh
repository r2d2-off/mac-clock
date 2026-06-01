#!/usr/bin/env bash
set -euo pipefail

APP_DEST="/Applications/IP Time.app"
DAEMON_DEST="/usr/local/libexec/iptime-daemon"
SUPPORT_DIR="/Library/Application Support/IPTime"
PLIST="/Library/LaunchDaemons/local.iptime.daemon.plist"
LABEL="local.iptime.daemon"
AGENT_LABEL="local.iptime.menubar"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

killall DualTimeMenuBar >/dev/null 2>&1 || true
launchctl bootout "gui/$(id -u)" "$AGENT_PLIST" >/dev/null 2>&1 || true
rm -f "$AGENT_PLIST"

sudo launchctl bootout system "$PLIST" >/dev/null 2>&1 || true
sudo rm -f "$PLIST"
sudo rm -f "$DAEMON_DEST"
sudo rm -rf "$APP_DEST"

if [[ "${1:-}" == "--purge" ]]; then
    sudo rm -rf "$SUPPORT_DIR"
    rm -rf "$HOME/Library/Application Support/IPTime"
fi

echo "Uninstalled IP Time."
echo "Status/config files were kept unless you passed --purge."
