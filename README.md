# IP Time

macOS menu bar clock for VPN work:

```text
[🇷🇺 Mon Jun 1 19:07    🇳🇱 18:07  203.0.113.42]
```

The first segment is always Moscow time (`Europe/Moscow`). The second segment
is the current system time after the VPN-region timezone is applied. A root
LaunchDaemon checks the external IP region every 10 minutes, and also rechecks
shortly after macOS reports a network, Wi-Fi, route, or DNS change. As a
fallback, it compares the current network fingerprint every 5 seconds and
rechecks when route, DNS, interface, or AirPort state changes. It updates the
system timezone and safe user regional preferences, then writes status for the
menu bar app.

Network-triggered checks are debounced for 5 seconds and run at most once every
10 seconds. If another network change happens inside that window, the daemon
delays the recheck instead of dropping it.

Use `Recheck IP Now` from the menu to force an immediate check after connecting
a VPN manually. While the request is waiting for the root daemon result, the
menu bar switches to an animated `Checking IP` state and the menu item is
temporarily disabled to avoid duplicate requests.

Use `Settings -> IP Check Interval` to choose the regular background interval:
1, 5, 10, 15, 30, or 60 minutes. The daemon reads interval changes live.

If something fails, the VPN/IP segment turns red and the error is shown in the
menu.

The menu bar app checks GitHub Releases once at launch and then every 6 hours.
Choose `Check Update...` to check manually; the app shows an alert saying
whether it is up to date, an update is available, or the check failed. When an
update is available, choose `Install Update ...` from the menu or the alert. The
app writes an update request and shows update progress while the root
LaunchDaemon downloads the release zip and replaces the installed app and daemon
without another installer prompt.

See [CHANGELOG.md](CHANGELOG.md) for release history.

## Install From Source

On a new Mac:

```sh
git clone https://github.com/r2d2-off/mac-clock.git
cd mac-clock
./scripts/install.sh
```

If Swift is missing, install Xcode Command Line Tools once:

```sh
xcode-select --install
```

`install.sh` asks for the admin password once. After that, the LaunchDaemon runs
as root, timezone changes do not prompt again, and the menu bar app starts
automatically at login.

## Install From A DMG

Download the latest `.dmg` from GitHub Releases, open it, then double-click:

```text
IP Time.pkg
```

The native macOS installer asks for the admin password once, installs the menu
bar app and root LaunchDaemon, then opens `IP Time.app`.

The release package is unsigned. If macOS says it cannot verify the installer,
Control-click the package and choose Open, or allow it from System Settings ->
Privacy & Security.

Build a DMG locally:

```sh
./scripts/package_dmg.sh
```

The DMG is created at:

```text
.build/IPTime-macos-<arch>.dmg
```

Build a standalone package installer locally:

```sh
./scripts/package_pkg.sh
```

The package is created at:

```text
.build/IPTime-macos-<arch>.pkg
```

## Install From A Release Zip

Build a zip on one Mac:

```sh
./scripts/package_release.sh
```

Upload the printed `.zip` file to GitHub Releases. On another Mac, unzip it and
run:

```sh
./install_prebuilt.sh
```

The zip is built for the current Mac architecture, for example `arm64`.

## Uninstall

```sh
./scripts/uninstall.sh
```

To remove status and user config too:

```sh
./scripts/uninstall.sh --purge
```

## Troubleshooting

If the menu bar keeps showing stale IP data after an update, check the daemon:

```sh
launchctl print system/local.iptime.daemon
```

If it shows `spawn failed` or `EX_CONFIG`, install the latest `.pkg` from the
DMG once. Current releases re-register the LaunchDaemon after replacing the root
daemon binary so future self-updates can restart cleanly.

## What Gets Installed

```text
/Applications/IP Time.app
/usr/local/libexec/iptime-daemon
/Library/LaunchDaemons/local.iptime.daemon.plist
/Library/Application Support/IPTime/status.json
~/Library/LaunchAgents/local.iptime.menubar.plist
~/Library/Application Support/IPTime/config.json
~/Library/Application Support/IPTime/recheck-request.json
~/Library/Application Support/IPTime/update-request.json
~/Library/Application Support/IPTime/update-result.json
```

## IP And Locale Rules

The daemon uses `http://ip-api.com/json` for external IP, country code, city,
region, and timezone detection.

Supported regional mappings:

```text
PL -> Europe/Warsaw      -> pl_PL  -> metric, Celsius, Monday
AE -> Asia/Dubai         -> en_AE  -> metric, Celsius, Monday
DE -> Europe/Berlin      -> de_DE  -> metric, Celsius, Monday
NL -> Europe/Amsterdam   -> nl_NL  -> metric, Celsius, Monday
FR -> Europe/Paris       -> fr_FR  -> metric, Celsius, Monday
US -> America/New_York   -> en_US  -> imperial, Fahrenheit, Sunday
RU -> Europe/Moscow      -> ru_RU  -> metric, Celsius, Monday
SG -> Asia/Singapore     -> en_SG  -> metric, Celsius, Monday
CN -> Asia/Shanghai      -> zh_CN  -> metric, Celsius, Monday
```

The daemon changes these active-user preferences automatically:

```text
AppleLocale
AppleMetricUnits
AppleMeasurementUnits
AppleTemperatureUnit
AppleFirstWeekday
```

App language is intentionally kept English-only. The daemon does not change
`AppleLanguages`. The pkg installer sets `AppleLanguages` to English once for
the active user; source and zip installs leave it unchanged. Set it manually if
needed:

```sh
defaults write NSGlobalDomain AppleLanguages -array "en-US"
```

The app intentionally does not change keyboard layouts, Apple ID/App Store
region, Location Services, browser settings, DNS, WebRTC, or 12/24-hour system
time format. Keyboard input sources are separate from app language; keeping
English and Russian layouts enabled is fine.

## Replace The macOS Clock Visually

macOS does not let third-party apps replace the system clock in-place. To get
the same visual result:

1. Open System Settings.
2. Go to Control Center.
3. Hide or minimize the system Clock menu bar display.
4. Run `IP Time.app`.

The installer creates `~/Library/LaunchAgents/local.iptime.menubar.plist`, so
the menu bar app starts automatically after login.
