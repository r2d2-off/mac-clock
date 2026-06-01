# Changelog

All notable IP Time changes are recorded here. Release artifacts are published
on GitHub Releases.

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
