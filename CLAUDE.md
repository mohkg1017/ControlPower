# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ControlPower is a native macOS menu bar utility that manages sleep-related `pmset` options via a privileged helper daemon. The app communicates with a root-level helper over XPC (Mach service) to run `pmset` commands that require `sudo`.

## Build Commands

Project uses XcodeGen (`project.yml` → `.xcodeproj`). Regenerate after changing `project.yml`:

```bash
xcodegen generate
```

Build (Debug):
```bash
xcodebuild -project ControlPower.xcodeproj -scheme ControlPower -configuration Debug -destination 'platform=macOS' build
```

Run tests:
```bash
xcodebuild -project ControlPower.xcodeproj -scheme ControlPower -configuration Debug -destination 'platform=macOS,arch=arm64' test
```

Run a single test (XCTest):
```bash
xcodebuild test -project ControlPower.xcodeproj -scheme ControlPower -destination 'platform=macOS,arch=arm64' -only-testing:ControlPowerTests/ControlPowerTests/testRefreshStatusSuccess
```

Signed release:
```bash
DEVELOPER_ID_APP='Developer ID Application: ...' NOTARY_PROFILE='notary-profile' scripts/release.sh 1.0.0 1
```

## Architecture

### Targets (defined in `project.yml`)

| Target | Type | Purpose |
|---|---|---|
| `ControlPowerHelper` | CLI tool | Privileged daemon — runs `pmset` as root |
| `ControlPowerCore` | Framework | Business logic (`AppViewModel`, `PowerDaemonClient`, shared models) |
| `ControlPower` | App | UI layer (SwiftUI views, MenuBarExtra) — embeds Core + Helper |
| `ControlPowerTests` | Unit tests | Hostless tests against `ControlPowerCore` |

### Source Layout

- **`App/Sources/`** — SwiftUI views (`MainView`, `MenuBarPanelView`, `ControlPowerApp`) + core logic (`AppViewModel`, `PowerDaemonClient`)
- **`Helper/Sources/`** — XPC listener (`main.swift`) and service implementation (`HelperService.swift`)
- **`Shared/Sources/`** — XPC protocol, power models, `PMSetParser`, `TimedProcessRunner` (shared between app and helper)
- **`Tests/`** — XCTest + Swift Testing tests with `FakePowerDaemonClient` (Mutex-backed thread-safe fake)

### IPC Pattern

The app and helper communicate via Mach service XPC (`com.moe.controlpower.helper.mach`):

1. Helper binary is embedded at `Contents/Resources/ControlPowerHelper`
2. LaunchDaemon plist registered via `SMAppService.daemon(plistName:)` — starts on demand
3. App connects via `NSXPCConnection(machServiceName:options:.privileged)`
4. Helper validates each connection's code signature (bundle ID + team ID) via `SecCode` APIs
5. `XPCReplyGate<T>` prevents double-resume of `CheckedContinuation` across concurrent XPC reply/interruption/invalidation paths

### Key Patterns

- **Swift 6 strict concurrency** (`SWIFT_STRICT_CONCURRENCY = complete`) throughout
- **`@MainActor @Observable` AppViewModel** owns all state: power status, serial mutation queue, timed presets, battery monitoring
- **Mutation serialization**: `pendingMutations` queue ensures `setDisableSleep`/`restoreDefaults` never run concurrently
- **`PowerDaemonClient`** is a `Sendable` struct; falls back to local `pmset -g` if helper is unavailable
- **`TimedProcessRunner`**: wraps `Process` with 8s timeout and SIGKILL fallback (used by both app and helper)

## Build Configurations

| Config | Use |
|---|---|
| Debug | Development — incremental, `-Onone`, active arch only |
| Profiling | Instruments — same as Debug + profiling entitlements (`ControlPowerProfiling.entitlements`) |
| Release | Distribution — whole-module, `-O`, LTO, hardened runtime, no debug entitlements |

## Release Signing

- Release builds use `DEVELOPER_ID_APP` identity; `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` prevents Xcode from injecting debug entitlements
- `scripts/check-release-entitlements.sh` verifies no `disable-library-validation` or `get-task-allow=true` in the signed app
- Helper has no entitlements file — bare code signature only

## Deployment Target

macOS 26.0 across all targets.
