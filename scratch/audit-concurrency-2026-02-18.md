# Swift Concurrency Audit — ControlPower
**Date**: 2026-02-18
**Scope**: App/Sources/, Helper/Sources/, Shared/Sources/

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH | 5 |
| MEDIUM | 3 |
| LOW | 1 |
| **Total** | **9** |

**Swift 6 Readiness**: NOT READY — multiple `@unchecked Sendable` and `nonisolated(unsafe)` annotations suppress compiler enforcement.

## HIGH Issues

### H1 — `nonisolated(unsafe)` on client property
**File**: `App/Sources/AppViewModel.swift:29`
`nonisolated(unsafe) private let client: any PowerDaemonClientProtocol`
Opts the property out of Swift concurrency checking entirely. Unnecessary since AppViewModel is @MainActor and client is only accessed from main actor context.
**Fix**: Remove `nonisolated(unsafe)`. Add `Sendable` to `PowerDaemonClientProtocol`.

### H2 — `@unchecked Sendable` on PowerDaemonClient
**File**: `App/Sources/PowerDaemonClient.swift:32`
Bypasses compiler thread-safety verification. If stored mutable state is added in future, `@unchecked` silently becomes incorrect.
**Fix**: Convert to `struct` (implicitly `Sendable`) or use `actor` isolation.

### H3 — `@unchecked Sendable` retroactive conformance on NSXPCConnection
**File**: `App/Sources/PowerDaemonClient.swift:4`
`extension NSXPCConnection: @retroactive @unchecked Sendable {}`
Necessary but undocumented. The usage pattern is actually safe (XPCReplyGate uses NSLock for one-shot delivery), but the suppression should be documented.
**Fix**: Add comment explaining why this conformance is safe.

### H4 — Bare `Task {}` without `[weak self]` in startup/toggleHelper
**Files**: `App/Sources/AppViewModel.swift:68, 90, 172`
Implicit strong captures of `self` prevent deallocation if the view model is ever released while tasks are in-flight. Inconsistent with `[weak self]` used in `setupBatteryMonitoring`.
**Fix**: `Task { [weak self] in await self?.refreshStatus() }`

### H5 — GCD `asyncAfter` timeout inside async continuation — not cancellable
**File**: `App/Sources/PowerDaemonClient.swift:207`
`DispatchQueue.global(qos: .userInitiated).asyncAfter(...)` timeout always fires after 8s even when XPC succeeds. The XPCReplyGate NSLock prevents double-resume, but the GCD timer is a resource waste.
**Fix**: Replace with a cancellable `Task.sleep`-based timeout sibling task.

## MEDIUM Issues

### M1 — `TimedProcessRunner.run()` blocks @MainActor thread
**File**: `App/Sources/AppViewModel.swift:176-177`
`TimedProcessRunner.run()` is called from `updateBatteryLevel()` which runs on `@MainActor`. The semaphore `.wait(timeout:)` inside blocks the main thread for up to 5 seconds.
**Fix**: Wrap in `Task.detached(priority: .utility)` matching the pattern in `PowerDaemonClient.fetchStatus`.

### M2 — `HelperService` and `HelperListenerDelegate` lack concurrency annotations
**File**: `Helper/Sources/HelperService.swift`, `Helper/Sources/main.swift`
XPC calls arrive on arbitrary background threads. The helper runs `RunLoop.main.run()` but has no `@MainActor` annotation to make this explicit to the compiler.
**Fix**: Annotate both classes `@MainActor` to match the RunLoop threading model.

### M3 — `AppViewModel.init` isolation not explicit
**File**: `App/Sources/AppViewModel.swift:34`
`init` should be explicitly `@MainActor` to make the isolation requirement visible at call sites.
**Fix**: Add `@MainActor` to `init`.

## LOW Issues

### L1 — `XPCReplyGate` uses NSLock where `Mutex` is preferred in Swift 6
**File**: `App/Sources/PowerDaemonClient.swift:247-275`
`NSLock` + `@unchecked Sendable` is correct but unverifiable. `Mutex` from `Synchronization` (macOS 15+) would make the conformance compiler-verifiable.
**Fix**: Replace NSLock with `Mutex<State>` from `import Synchronization`.

## Immediate Actions

1. Add `[weak self]` to Task captures in startup(), toggleHelper(), setupBatteryMonitoring()
2. Move TimedProcessRunner.run() off @MainActor in updateBatteryLevel() — wraps in Task.detached
3. Replace GCD timeout with cancellable Task.sleep-based sibling task
4. Add Sendable to PowerDaemonClientProtocol, remove nonisolated(unsafe)
5. Enable `-strict-concurrency=complete` and resolve warnings before Swift 6 mode
