<p align="center">
  <img src="docs/assets/controlpower-logo.png" alt="ControlPower" width="900">
</p>

ControlPower is a native macOS menu bar utility to manage sleep-related `pmset` options with a privileged helper.

## Features

- One-click toggle for `sudo pmset -a disablesleep 1/0`
- Status view for `lidwake` from `pmset -g`
- One-click restore defaults (`disablesleep 0`, `lidwake 1`)
- Current status view using `pmset -g`

## Build

```bash
xcodegen generate
xcodebuild -project ControlPower.xcodeproj -scheme ControlPower -configuration Debug -destination 'platform=macOS' build
```

## Release

```bash
DEVELOPER_ID_APP='Developer ID Application: ...' NOTARY_PROFILE='notary-profile' scripts/release.sh 1.0.0 1
```

`scripts/release.sh` now uses `xcodebuild archive` and requires `DEVELOPER_ID_APP` for signing. It then attempts `xcodebuild -exportArchive` and copies the app dSYM from the archive into `.release/archives`.

## Install to Applications

```bash
scripts/install_to_applications.sh
```

The installer now stages the new app and backs up any existing `/Applications/ControlPower.app` before replacing it.

Install with a custom name (for distribution/testing side-by-side):

```bash
scripts/install_to_applications.sh --target /Applications/MoeRelease.app
```

Or use the shortcut wrapper:

```bash
scripts/install_moe_release.sh
```

`scripts/install_moe_release.sh` only installs/renames the built app in `/Applications`; it does not create a signed release package.

## One-Click Release Builder App

Install a launcher app that opens Terminal and runs the signed release pipeline (`scripts/release.sh`):

```bash
scripts/install_controlpower_release_app.sh
```

This installs `/Applications/ControlPowerRelease.app`.

On first install, it creates `~/.controlpower-release.env`. Fill it with your signing values:

```bash
DEVELOPER_ID_APP='Developer ID Application: Your Name (TEAMID)'
# Optional for notarization:
# NOTARY_PROFILE='your-notary-profile'
```

Then launch `ControlPowerRelease.app` from Applications and follow prompts for version/build.

Tip: list valid signing identities with:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

`ControlPowerRelease.app` runs tests by default. To skip tests intentionally, launch it from Terminal with:

```bash
SKIP_TESTS=1 scripts/run_release_from_launcher.sh
```

Notarization is required by default. To intentionally build a non-notarized DMG, set:

```bash
ALLOW_UNNOTARIZED_RELEASE=1 scripts/run_release_from_launcher.sh
```

## Xcode Agent Self-Heal (Codex + Claude)

Install event-based self-healing for Xcode Coding Assistant links/config:

```bash
scripts/install_xcode_agent_selfheal.sh
```

The installer copies the doctor script into `~/Library/Application Support/ControlPower/xcode-agent-selfheal/` so LaunchAgent execution is not blocked by Desktop/Documents privacy protections.

Run a manual health check at any time:

```bash
scripts/doctor_xcode_agents_once.sh
```

Or run check-only mode (no repairs):

```bash
scripts/doctor_xcode_agents.sh --check-only --verbose
```

Remove the self-heal LaunchAgent:

```bash
scripts/install_xcode_agent_selfheal.sh --uninstall
```

The doctor script repairs:
- `~/Library/Developer/Xcode/CodingAssistant/Agents/Versions/*/{codex,claude}` symlinks
- `~/Library/Developer/Xcode/CodingAssistant/codex/config.toml` xcode profile block
- `~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/settings.json` model setting

It does not auto-upgrade binaries; it only points Xcode to whatever local `codex` and `claude` executables are already installed.

## Notes

- LaunchDaemon plist is bundled at `Contents/Library/LaunchDaemons/com.moe.controlpower.helper.v2.plist`.
- Helper binary is embedded at `Contents/MacOS/ControlPowerHelper` and exposed via Mach service `com.moe.controlpower.helper.v2.mach`.
- Helper starts on demand via Mach service instead of being forced to run continuously.
- Use the `ControlPowerProfiling` scheme or `-configuration Profiling` for Instruments captures with hardened runtime profiling entitlements.
- Verify release entitlements before distribution:
  - `scripts/check-release-entitlements.sh /path/to/ControlPower.app`
- CLI profiling helpers:
  - `scripts/record_time_profiler.sh`
  - `scripts/extract_time_samples.py`
  - `scripts/top_hotspots.py`
