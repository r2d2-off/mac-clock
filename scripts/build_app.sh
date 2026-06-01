#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$ROOT/.build/IP Time.app"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp "$BIN_DIR/DualTimeMenuBar" "$APP/Contents/MacOS/DualTimeMenuBar"
chmod +x "$APP/Contents/MacOS/DualTimeMenuBar"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>DualTimeMenuBar</string>
    <key>CFBundleIdentifier</key>
    <string>local.iptime.menubar</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>IP Time</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>__VERSION__</string>
    <key>CFBundleVersion</key>
    <string>__VERSION__</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

/usr/bin/sed -i '' "s/__VERSION__/$VERSION/g" "$APP/Contents/Info.plist"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "$APP"
