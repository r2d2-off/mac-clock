#!/usr/bin/env bash
set -euo pipefail

APP_DEST="/Applications/IP Time.app"
DAEMON_DEST="/usr/local/libexec/iptime-daemon"
SUPPORT_DIR="/Library/Application Support/IPTime"
PLIST="/Library/LaunchDaemons/local.iptime.daemon.plist"
LABEL="local.iptime.daemon"
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
KEEP_DATA=0
RESTORE_PREFS=1

usage() {
    cat <<'TEXT'
Usage: ./scripts/uninstall.sh [--keep-data] [--no-restore]

By default this restores saved macOS preferences and removes all IP Time files.
--keep-data    Keep status/config/backup files and logs.
--no-restore   Remove IP Time without restoring saved macOS preferences.
--purge        Accepted for compatibility; full cleanup is now the default.
TEXT
}

for arg in "$@"; do
    case "$arg" in
        --keep-data)
            KEEP_DATA=1
            ;;
        --no-restore)
            RESTORE_PREFS=0
            ;;
        --purge)
            KEEP_DATA=0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            usage >&2
            exit 2
            ;;
    esac
done

killall DualTimeMenuBar >/dev/null 2>&1 || true
launchctl bootout "gui/$(id -u)" "$AGENT_PLIST" >/dev/null 2>&1 || true
sudo launchctl bootout system "$PLIST" >/dev/null 2>&1 || true

if [[ "$RESTORE_PREFS" == "1" ]]; then
    if [[ -f "$USER_RESTORE_SCRIPT" ]]; then
        /bin/sh "$USER_RESTORE_SCRIPT" || true
    fi

    if [[ -f "$SYSTEM_RESTORE_SCRIPT" ]]; then
        sudo /bin/sh "$SYSTEM_RESTORE_SCRIPT" || true
    fi
fi

rm -f "$AGENT_PLIST"
sudo rm -f "$PLIST"
sudo rm -f "$DAEMON_DEST"
sudo rm -rf "$APP_DEST"

if [[ "$KEEP_DATA" == "0" ]]; then
    sudo rm -rf "$SUPPORT_DIR"
    rm -rf "$USER_SUPPORT_DIR"
    sudo rm -f "${SYSTEM_LOGS[@]}"
    rm -f "${USER_LOGS[@]}"
fi

echo "Uninstalled IP Time."
if [[ "$KEEP_DATA" == "1" ]]; then
    echo "Status/config/backup/log files were kept."
else
    echo "Removed status/config/backup/log files."
fi
