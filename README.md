# IP Time

macOS menu bar IP/VPN clock:
<img width="1700" height="194" alt="image" src="https://github.com/user-attachments/assets/42be8623-ecde-4c64-9c6a-a45c635ccb9a" />

On first launch IP Time is observe-only: it checks the external IP and shows the
home/team clock plus detected country flag and IP address, but it does not
change the macOS timezone, locale, measurement units, temperature unit, or first
weekday. The main menu shows explicit `Allow ...` approvals for each setting,
and the same controls are also available under `Settings -> Allowed Changes`.

The first menu bar segment is the configurable home/team clock. It defaults to
Moscow time (`Europe/Moscow`) and can be changed to a preset city timezone or a
fixed UTC offset under `Settings -> Home Clock`. The second segment is the
detected IP region. When any allowed change is enabled, the second segment also
shows the current system time.

A root LaunchDaemon checks the external IP region every 10 minutes, and also
rechecks shortly after macOS reports a network, Wi-Fi, route, or DNS change. As
a fallback, it compares the current network fingerprint every 5 seconds and
rechecks when route, DNS, interface, assigned IPv4, or router state changes. It
writes status for the menu bar app. It changes the system timezone only when
`Allowed Changes -> System Time Zone` is enabled.

External IP, country, and timezone are checked via `ip-api.com`.

Network-triggered checks are debounced for 5 seconds and run at most once every
10 seconds. If another network change happens inside that window, the daemon
delays the recheck instead of dropping it.

The network fingerprint is intentionally narrow: primary interface, primary
service, router, assigned IPv4 address, and DNS values. This avoids rechecking
because of noisy AirPort or temporary IPv6 state changes.

Use `Recheck IP Now` from the menu to force an immediate check after connecting
a VPN manually. While any IP check is running, manual, network-triggered, or
scheduled, the VPN segment keeps its normal layout and shows a small animated
comet indicator next to the IP address. When the check finishes, it briefly
draws a green checkmark. The menu item is temporarily disabled while a check is
already running to avoid duplicate requests.

`Quit IP Time` is a full stop for the current app installation: it restores
saved user preferences, asks the root daemon to restore saved system
preferences, disables and stops the LaunchDaemon, removes the LaunchAgent, and
closes the menu bar app. Opening `IP Time.app` again recreates the LaunchAgent
and hands off to the launchd-managed menu bar instance, then starts the
LaunchDaemon again. If the daemon was stopped, macOS asks for an administrator
password because starting a root LaunchDaemon requires elevated privileges.

Use `Settings -> Home Clock` to change the left clock. `Presets` uses real IANA
timezones with country flags, so daylight saving time is handled correctly.
`Fixed UTC Offset` uses compact team-time offsets such as `UTC+03:00` or
`UTC-07:00` without changing the macOS system timezone.

Current Home Clock presets are Moscow, California, New York, Dubai, Shanghai,
Singapore, Bangkok, Berlin, Amsterdam, Paris, London, Warsaw, and Tokyo. Home
Clock presets only affect the left menu bar clock; they do not control VPN
regional preference rules.

Use `Settings -> IP Check Interval` to choose the regular background interval:
1, 5, 10, 15, 30, or 60 minutes. The daemon reads interval changes live.

If the IP lookup fails before the daemon receives an IP address, the VPN/IP
segment shows a red `ip-api.com error` state. The full error is shown in the
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
as root, permitted timezone changes do not prompt again, and the menu bar app
starts automatically at login. Installation does not enable any regional
changes by default.

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

By default this restores saved macOS preferences and removes app, daemon,
LaunchAgent, LaunchDaemon, status, config, backup, and log files.

To keep status, config, backup, and log files:

```sh
./scripts/uninstall.sh --keep-data
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
/Library/Application Support/IPTime/check-state.json
/Library/Application Support/IPTime/region-sync-restore-state.json
/Library/Application Support/IPTime/original-system-preferences.json
/Library/Application Support/IPTime/restore-system-preferences.sh
~/Library/LaunchAgents/local.iptime.menubar.plist
~/Library/Application Support/IPTime/config.json
~/Library/Application Support/IPTime/region-sync-restore-state.json
~/Library/Application Support/IPTime/original-user-preferences.json
~/Library/Application Support/IPTime/restore-user-preferences.sh
~/Library/Application Support/IPTime/daemon-stop-state.json
~/Library/Application Support/IPTime/recheck-request.json
~/Library/Application Support/IPTime/stop-request.json
~/Library/Application Support/IPTime/update-request.json
~/Library/Application Support/IPTime/update-result.json
/Library/Logs/IPTimeDaemon.out.log
/Library/Logs/IPTimeDaemon.err.log
/Library/Logs/IPTimeInstaller.log
~/Library/Logs/IPTimeMenuBar.out.log
~/Library/Logs/IPTimeMenuBar.err.log
```

## IP And Locale Rules

The daemon uses the free `http://ip-api.com/json` endpoint for external IP,
country code, city, region, and timezone detection. This endpoint is
intentionally HTTP because the free ip-api.com API does not serve this route over
HTTPS.

The daemon validates the ip-api.com response before changing system settings. It
rejects invalid IP addresses, non-success API statuses, invalid country codes,
unsupported countries, invalid timezones, overlong display fields, and control
or format characters.

Supported VPN regional mappings:

These mappings are used when the current external IP country is recognized. The
root daemon applies only the system timezone permission. The per-user menu bar
LaunchAgent applies only the enabled active-user regional preference
permissions.

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

`Settings -> Allowed Changes` controls each managed setting independently:

```text
System Time Zone  -> macOS system timezone, applied by the root daemon
Locale            -> AppleLocale, applied by the menu bar LaunchAgent
Measurement Units -> AppleMetricUnits and AppleMeasurementUnits
Temperature Unit  -> AppleTemperatureUnit
First Weekday     -> AppleFirstWeekday
```

The menu bar LaunchAgent can change these active-user preferences when the
matching permission is enabled:

```text
AppleLocale
AppleMetricUnits
AppleMeasurementUnits
AppleTemperatureUnit
AppleFirstWeekday
```

Before the first allowed regional change, the root daemon stores the original
system timezone once, and the menu bar LaunchAgent stores the original
active-user regional preferences once. Disabling an allowed change restores that
setting from the saved baseline when a baseline exists, then stops future
changes for that setting. Uninstall runs the same restore scripts before
removing files.

App language is intentionally kept English-only. The app, daemon, and installer
do not change `AppleLanguages`. Set it manually if needed:

```sh
defaults write NSGlobalDomain AppleLanguages -array "en-US"
```

The app intentionally does not change keyboard layouts, Apple ID/App Store
region, Location Services, browser settings, DNS, WebRTC, or 12/24-hour system
time format.

## Replace The macOS Clock Visually

macOS does not let third-party apps replace the system clock in-place. To get
the same visual result:

1. Open System Settings.
2. Go to Control Center.
3. Hide or minimize the system Clock menu bar display.
4. Run `IP Time.app`.

The installer creates `~/Library/LaunchAgents/local.iptime.menubar.plist`, so
the menu bar app starts automatically after login.
