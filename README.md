# ControlPower

ControlPower is a native macOS menu bar utility to manage sleep-related `pmset` options with a privileged helper.

## Features

- Menu bar controls for `disablesleep` and `lidwake`
- Presets for common power profiles
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

## Install to Applications

```bash
scripts/install_to_applications.sh
```

## Notes

- LaunchDaemon plist is bundled at `Contents/Library/LaunchDaemons/com.moe.controlpower.helper.plist`.
- Helper binary is embedded at `Contents/Resources/ControlPowerHelper` and exposed via Mach service `com.moe.controlpower.helper.mach`.
