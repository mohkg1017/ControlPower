# SwiftUI Architecture Audit — ControlPower
**Date**: 2026-02-18
**Scope**: App/Sources/

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 3 |
| HIGH | 3 |
| MEDIUM | 2 |
| LOW | 1 |
| **Total** | **9** |

## CRITICAL Issues

### C1 — Timer Task async boundary violation + side-effect entanglement
**File**: `App/Sources/AppViewModel.swift:118-130`
`timerTask = Task { ... }` lacks `@MainActor` annotation on body. After each `await Task.sleep` suspension, cancellation check races with `toggleDisableSleep()` call at loop exit. Setting `remainingSeconds = nil` then calling `toggleDisableSleep()` creates an intermediate state where UI renders nil but toggle hasn't fired yet.
**Fix**: Add `@MainActor` to Task body. Separate the side-effect: set a flag, don't call `toggleDisableSleep()` directly from timer loop.

### C2 — refreshStatus() race: isBusy guard checked before first await
**File**: `App/Sources/AppViewModel.swift:71-81`
`guard !isBusy else { return }` is checked but `isBusy = true` is set inside `perform()` — after the first `await`. Rapid double-tap or concurrent calls from startup + user both pass the guard, resulting in two concurrent `client.fetchStatus()` calls both writing to `snapshot`.
**Fix**: Set `isBusy = true` synchronously before the first `await`.

### C3 — `nonisolated(unsafe)` on client property suppresses actor safety
**File**: `App/Sources/AppViewModel.swift:29`
See concurrency audit H1. Unnecessary suppression since `AppViewModel` is `@MainActor` and `client` is only accessed from main actor context.
**Fix**: Remove `nonisolated(unsafe)`.

## HIGH Issues

### H1 — ObservableObject / @ObservedObject instead of @Observable
**Files**: `AppViewModel.swift:11-12`, `MainView.swift:4`, `MenuBarPanelView.swift:4`
8 `@Published` properties mean any single property change re-renders ALL `@ObservedObject` subscriber views. The 1-second `remainingSeconds` countdown re-renders both `MainView` and `MenuBarPanelView` entirely on every tick even though `MenuBarPanelView` doesn't use `remainingSeconds`.
**Fix**: Migrate to `@Observable` macro, `@State` at root, plain `var` in child views. Eliminates coarse-grained observation.

### H2 — statusIcon / statusColor / statusTitle duplicated across views
**Files**: `MainView.swift:305-335`, `MenuBarPanelView.swift:118-140`
Presentation logic duplicated across two views with already-diverging values (`"No Sleep Active"` vs `"No Sleep ON"`). A third view would need a third copy.
**Fix**: Move `statusIcon`, `statusColor`, `statusTitle`, `statusDescription` to `AppViewModel` as computed properties.

### H3 — AppViewModel imports AppKit
**File**: `App/Sources/AppViewModel.swift:1`
Only AppKit usage is `NSApp.terminate(nil)` in `quitApp()`. Couples business logic to UI framework, forces AppKit linkage in tests.
**Fix**: Move `quitApp()` to `ControlPowerApp`. ViewModel exposes a quit intent (notification/closure). App layer calls `NSApp.terminate(nil)`.

## MEDIUM Issues

### M1 — Inline Binding(get:set:) in view body
**Files**: `MainView.swift:103-106`, `MenuBarPanelView.swift:69-72`
Custom `Binding` objects re-allocated every render pass. The `_ in` setter pattern signals command-based state (appropriate for XPC-backed toggles) but `Toggle` implies two-way binding. Misleading intent.
**Fix**: Extract to computed `var` properties outside `body`, or use `Button` styled as toggle for command-based actions.

### M2 — Combine import retained solely for 60s timer
**File**: `App/Sources/AppViewModel.swift:27, 162-172`
`Timer.publish.autoconnect().sink` bridges Combine to Swift Concurrency via a nested `Task`. Adds `import Combine` dependency, `AnyCancellable?` storage, and nested `[weak self]` closures unnecessarily.
**Fix**: Replace with `Task`-based async loop. Eliminates `import Combine` from ViewModel.

## LOW Issues

### L1 — sourceText() should be a computed property
**File**: `App/Sources/AppViewModel.swift:151-158`
Pure derivation with no side effects called as `viewModel.sourceText()`. Convention: side-effect-free derivations = computed `var`, not methods.
**Fix**: Change to `var sourceText: String { ... }`.

## Recommended Fix Order

1. C3 — Remove nonisolated(unsafe) (1-line fix)
2. C2 — Set isBusy = true before first await in refreshStatus()
3. C1 — Add @MainActor to timer Task body, decouple side effect
4. H1 — Migrate to @Observable (unlocks M1, M2 naturally)
5. H2 — Consolidate status display properties in ViewModel
6. H3 — Move quitApp() to App layer, remove import AppKit
7. M1 — Extract Binding to computed properties
8. M2 — Replace Combine timer with Task loop
9. L1 — Convert sourceText() to computed property
