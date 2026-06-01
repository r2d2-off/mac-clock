# Changelog

All notable IP Time changes are recorded here. Release artifacts are published
on GitHub Releases.

## Unreleased

## v0.1.38 - 2026-06-02

- Keeps the Home Clock visible in the menu bar even when no regional changes are
  allowed.
- Adds explicit `Allow ...` regional approval toggles directly in the main menu
  details area, above the status rows.

## v0.1.37 - 2026-06-02

- Changed first-launch behavior to observe-only: IP Time now checks and shows
  the external IP region without changing macOS settings until the user enables
  explicit permissions.
- Replaced the single Automatic Region Sync toggle with `Settings -> Allowed
  Changes` permissions for system timezone, locale, measurement units,
  temperature unit, and first weekday.
- Restores a disabled permission from the saved baseline when a baseline exists,
  then stops applying future changes for that setting.
- Shows only the detected country flag and IP address in the menu bar while no
  regional changes are allowed.

## v0.1.36 - 2026-06-02

- Moved menu-bar regional preference synchronization off the main thread onto a
  serial background queue.
- Avoided re-reading user regional defaults when daemon status changes but the
  target regional preference values are unchanged.
- Suppressed scheduled and network-triggered daemon region checks while
  Automatic Region Sync is off, after the one-time restore has completed.

## v0.1.35 - 2026-06-02

- Updated source and DMG uninstall flows to remove IP Time log files during
  full cleanup.

## v0.1.34 - 2026-06-02

- Added one-time backups for the original system timezone and active-user
  regional preferences before the daemon applies regional changes.
- Added `Settings -> Automatic Region Sync`; turning it off restores saved
  preferences and stops future automatic timezone/locale changes.
- Cached active-user detection in the daemon loop instead of spawning `stat`,
  `id`, and `dscl` once per second while idle.
- Moved active-user regional preference backup/apply/restore out of the root
  daemon and into the per-user menu bar LaunchAgent.
- Limited Region Sync restore to the disable transition instead of repeating it
  on every scheduled check while sync is off.
- Updated source and DMG uninstall flows to restore saved preferences before
  removing IP Time files, with full support-data cleanup as the default.
- Removed the pkg installer's one-time `AppleLanguages=en-US` write.
- Clarified the README distinction between VPN regional mappings and Home Clock
  presets, and listed the current Home Clock presets.

## v0.1.33 - 2026-06-01

- Added strict validation for ip-api.com responses before the daemon applies any
  system timezone or user regional preference changes.
- The daemon now rejects invalid IP addresses, non-success API statuses, invalid
  country codes, unsupported countries, invalid timezones, overlong text fields,
  and control characters in display text.
- README now states explicitly that external IP, country, and timezone checks are
  done via `ip-api.com`.
- Removed the README note about keyboard input sources.

## v0.1.32 - 2026-06-01

- Added an explicit red `ip-api.com error` state in the VPN/IP menu bar segment
  when the region lookup fails before returning an IP address.
- Documented that the app intentionally uses the free HTTP-only ip-api.com
  endpoint for IP, region, and timezone detection.

## v0.1.31 - 2026-06-01

- Reduced noisy automatic IP rechecks by replacing the raw macOS network
  dictionary fingerprint with a compact fingerprint of primary interface,
  service, router, assigned IPv4 address, and DNS values.
- Manual `Recheck IP Now` now cancels pending network-triggered rechecks and
  refreshes the network fingerprint baseline after the manual check completes.
- Regional user preferences are now written only when the current value differs
  from the desired region value.

## v0.1.30 - 2026-06-01

- Added Bangkok (`Asia/Bangkok`, Thailand) to `Settings -> Home Clock -> Presets`.
- Changed the IP check comet indicator from the accent color to the same muted
  color as the IP address text.

## v0.1.29 - 2026-06-01

- Replaced the IP check pulsing dot with a smoother comet-tail activity
  indicator next to the IP address.
- Added a short green completion checkmark after manual, network-triggered, or
  scheduled IP checks finish.
- Added a dedicated 60 fps redraw timer inside the menu bar view while the IP
  check indicator is visible, without increasing JSON/status polling frequency.

## v0.1.28 - 2026-06-01

- Added `Settings -> Home Clock` for the left menu bar clock.
- Added curated city timezone presets with flags for Moscow, California, New
  York, Dubai, Shanghai, Singapore, Berlin, Amsterdam, Paris, London, Warsaw,
  and Tokyo.
- Added compact fixed UTC offset choices for team clocks that do not need a
  specific city timezone.
- The home clock config is stored in the user `config.json` and does not change
  the macOS system timezone.
- Replaced the IP refresh spinner with a quieter pulsing dot next to the IP.

## v0.1.27 - 2026-06-01

- Reworked IP recheck progress display.
- The menu bar now keeps the normal VPN segment layout and shows a small
  animated ring next to the IP address instead of replacing the segment text.
- The root daemon now writes `check-state.json` for manual, network-triggered,
  and scheduled region checks, so the app can show activity for every IP
  refresh path.
- Manual `Recheck IP Now` is still disabled while an IP check is already
  running.

## v0.1.26 - 2026-06-01

- Added an animated `Checking IP` state in the menu bar while a manual
  `Recheck IP Now` request is waiting for the daemon result.
- Disabled duplicate manual recheck requests while one is already in progress.
- The menu now shows `Rechecking IP ...` for the manual recheck item until the
  fresh daemon status arrives.
- Status timestamps now include fractional seconds so fast manual rechecks clear
  precisely.

## v0.1.25 - 2026-06-01

- Added `Recheck IP Now` to the menu for immediate manual VPN/IP region checks.
- Added a `Settings -> IP Check Interval` submenu with 1, 5, 10, 15, 30, and
  60 minute interval choices.
- Added `config.json` for user-controlled region check interval settings.
- Added `recheck-request.json` as the menu bar app to root daemon control file
  for manual rechecks.
- The root daemon now reads interval changes live without restarting.

## v0.1.24 - 2026-06-01

- Fixed rapid Wi-Fi switching after a network-triggered region check.
- Network-triggered checks are no longer dropped when they happen inside the
  throttle window; they are rescheduled for the next allowed time.
- Reduced the minimum interval for network-triggered checks from 30 seconds to
  10 seconds.

## v0.1.23 - 2026-06-01

- Added a network fingerprint fallback in the root daemon.
- The daemon now compares macOS route, DNS, interface IPv4/IPv6, and AirPort
  state every 5 seconds and schedules a recheck when that fingerprint changes.
- This covers Wi-Fi switches even when the SystemConfiguration notification
  callback does not fire.

## v0.1.22 - 2026-06-01

- Fixed self-update daemon replacement on macOS launchd.
- After replacing `/usr/local/libexec/iptime-daemon`, the updater now schedules
  a root restart script that re-registers `local.iptime.daemon` with
  `bootout`, `bootstrap`, `enable`, and `kickstart`.
- This refreshes launchd's lightweight code requirement for the replaced daemon
  binary and prevents `EX_CONFIG` spawn failures after self-update.

## v0.1.21 - 2026-06-01

- Added a SystemConfiguration network-change monitor in the root daemon.
- The daemon now schedules an immediate region recheck after macOS reports a
  network, Wi-Fi, route, or DNS change, instead of waiting for the 10-minute
  region timer.
- Added a 5-second debounce and 30-second minimum interval for network-triggered
  checks so Wi-Fi reconnect bursts do not spam the IP API.
- Documented network-triggered region rechecks in README.

## v0.1.20 - 2026-06-01

- Added a user LaunchAgent so the menu bar app starts automatically after login
  and reboot.
- Updated install, zip install, pkg install, DMG uninstall, and source uninstall
  flows to create or remove `~/Library/LaunchAgents/local.iptime.menubar.plist`.
- Ignored system console users such as `_windowserver` when the root daemon
  starts before an interactive user login.
- Updated README to document automatic login startup.

## v0.1.19 - 2026-06-01

- Renamed manual update menu actions to `Check Update...`.

## v0.1.18 - 2026-06-01

- Added a macOS alert after manual update checks.
- The alert now reports up-to-date, update available, update in progress, or
  check failure states.
- Added an `Install Update` action directly from the update-available alert.

## v0.1.17 - 2026-06-01

- Added a progress window during self-update.
- Added a visible menu bar updating state while an update is requested or
  installing.
- Added LaunchDaemon update stages in `update-result.json`: validating,
  downloading, unpacking, installing, restarting, installed, and failed.
- Switched VPN region lookup to `http://ip-api.com/json` for more accurate
  country and timezone detection.

## v0.1.16 - 2026-06-01

- Showed visible update-check results in the menu.
- Manual checks now leave an understandable state in the menu: up to date,
  update available, or update check failed.

## v0.1.15 - 2026-06-01

- Fixed macOS pkg installation over older `IP Time.app` bundles.
- Disabled bundle version checking in the pkg component metadata.
- Forced app bundle replacement so old `1.0` builds are replaced by `0.1.x`
  builds.

## v0.1.14 - 2026-06-01

- Published the initial public-safe release.
- Added public GitHub Release update checks.
- Cleaned README examples and removed private-repository token flow.
- Reset repository history to a public-safe root commit.
