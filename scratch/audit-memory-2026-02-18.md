# Memory Leak Audit — ControlPower
**Date**: 2026-02-18
**Scope**: App/Sources/, Helper/Sources/, Shared/Sources/

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH | 2 |
| MEDIUM | 1 |
| LOW | 0 |
| **Total** | **3** |

All 3 issues are in `App/Sources/AppViewModel.swift`. Root cause: no `deinit` on `AppViewModel`.

## HIGH Issues

### H1 — Timer.publish AnyCancellable with no deinit teardown
**File**: `App/Sources/AppViewModel.swift:27, 162-170`
`batteryCheckTimer: AnyCancellable?` holds a `Timer.publish` repeating timer. No `deinit` means if `AppViewModel` is deallocated (tests, previews, future refactors), no explicit teardown occurs. If `batteryCheckTimer` is ever reassigned, the old timer is silently cancelled and a new one created without logging.
**Fix**: Add `deinit { batteryCheckTimer?.cancel(); batteryCheckTimer = nil; timerTask?.cancel() }`

### H2 — Strong `[self]` captures in pendingMutations closures
**File**: `App/Sources/AppViewModel.swift:102, 141`
Operation closures use `[self]` (strong capture) appended to `pendingMutations: [() async -> Void]`. The array holds strong references to `self` for the entire duration closures queue. Creates a temporal retain cycle — resolves only when queue drains. If XPC times out (8s per call), AppViewModel cannot be deallocated for up to 8s per queued operation.
**Fix**: Change `[self]` to `[weak self]` with `guard let self else { return }`.

## MEDIUM Issues

### M1 — timerTask without deinit cancellation
**File**: `App/Sources/AppViewModel.swift:22, 118-131`
`timerTask: Task<Void, Never>?` unstructured task captures `self` implicitly and strongly. Not automatically cancelled on actor deallocation. Active countdown timer holds `AppViewModel` alive, and `toggleDisableSleep()` may fire on a stale ViewModel.
**Fix**: Covered by deinit addition in H1. Confirm `Task.isCancelled` check is after sleep (already present at line 121).

## Fix Priority

1. Add `deinit` to `AppViewModel` cancelling both `timerTask` and `batteryCheckTimer` — fixes H1 + M1
2. Change `[self]` → `[weak self]` in operation closures at lines 102, 141 — fixes H2
