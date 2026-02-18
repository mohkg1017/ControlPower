# ControlPower

ControlPower is a native macOS menu bar utility to manage sleep-related `pmset` options with a privileged helper.

## Features

- Menu bar controls for `disablesleep` and `lidwake`
- Presets for common power profiles
- Saved preset picker with one-click apply in window/menu/commands
- Timed keep-awake sessions (30m / 1h / 2h) with automatic restore
- Helper status and registration controls
- Settings for launch-at-login, auto-refresh, and quit safety prompt

## Build

```bash
xcodegen generate
xcodebuild -project ControlPower.xcodeproj -scheme ControlPower -configuration Debug -destination 'platform=macOS' build
```

## Release

```bash
DEVELOPER_ID_APP='Developer ID Application: ...' NOTARY_PROFILE='notary-profile' scripts/release.sh 1.0.0 1
```

`scripts/release.sh` now uses `xcodebuild archive` and attempts `xcodebuild -exportArchive` when `DEVELOPER_ID_APP` is set. It also copies the app dSYM from the archive into `.release/archives`.

## Install to Applications

```bash
scripts/install_to_applications.sh
```

The installer now stages the new app and backs up any existing `/Applications/ControlPower.app` before replacing it.

## Notes

- LaunchDaemon plist is bundled at `Contents/Library/LaunchDaemons/com.moe.controlpower.helper.plist`.
- Helper binary is embedded at `Contents/Resources/ControlPowerHelper` and exposed via Mach service `com.moe.controlpower.helper.mach`.
- Helper starts on demand via Mach service instead of being forced to run continuously.
- Use the `ControlPowerProfiling` scheme or `-configuration Profiling` for Instruments captures with hardened runtime profiling entitlements.
- CLI profiling helpers:
  - `scripts/record_time_profiler.sh`
  - `scripts/extract_time_samples.py`
  - `scripts/top_hotspots.py`
