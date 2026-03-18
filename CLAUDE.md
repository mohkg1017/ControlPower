# CLAUDE.md

Minimal Claude guidance for this repo. Keep this file short; use `AGENTS.md` for workflow rules and `README.md` for fuller project/release details.

## Project

ControlPower is a native macOS menu bar app with a privileged helper daemon for `pmset` operations that require root.

## Key Paths

- `App/Sources`: SwiftUI app UI and app-facing logic
- `Helper/Sources`: privileged helper executable and XPC listener
- `Shared/Sources`: shared models, XPC protocol, and utilities
- `Tests`: unit tests
- `project.yml`: XcodeGen source of truth

## Commands

```bash
xcodegen generate --spec project.yml
xcodebuild -project ControlPower.xcodeproj -scheme ControlPower -configuration Debug -destination 'platform=macOS' build
xcodebuild -project ControlPower.xcodeproj -scheme ControlPower -destination "platform=macOS,arch=$(uname -m)" test
```

## Important Invariants

- Swift 6 strict concurrency is enabled; preserve actor isolation and `Sendable` correctness.
- Keep UI code in `App`, helper-only logic in `Helper`, and shared contracts in `Shared`.
- App/helper IPC uses the Mach service `com.moe.controlpower.helper.v2.mach`.
- Helper connection validation and XPC reply safety are security-critical; do not weaken them casually.
- Regenerate the Xcode project after changing `project.yml`.

## Release Notes

- Signed releases use `DEVELOPER_ID_APP`; optional notarization uses `NOTARY_PROFILE`.
- Do not commit signing credentials or other secrets.
