# Modernization Audit — ControlPower
**Date**: 2026-02-18
**Scope**: App/Sources/, Shared/Sources/
**Target**: macOS 14+ / iOS 17+

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 1 |
| HIGH | 6 |
| MEDIUM | 0 |
| LOW | 1 |
| **Total** | **8** |

## CRITICAL Issues

### C1 — AppViewModel uses ObservableObject (blocks all downstream migrations)
**File**: `App/Sources/AppViewModel.swift:12`
`final class AppViewModel: ObservableObject` with 8 `@Published` properties. Migration to `@Observable` is a prerequisite for all view property wrapper migrations. Without this, `@StateObject → @State` and `@ObservedObject → plain var` cannot be done.
**Fix**: 
```swift
import Observation
@MainActor @Observable
final class AppViewModel { ... }  // remove @Published, remove import Combine
```

## HIGH Issues

### H1 — @StateObject should migrate to @State
**File**: `App/Sources/ControlPowerApp.swift:5`
`@StateObject private var viewModel = AppViewModel()` → `@State private var viewModel = AppViewModel()`
Available once AppViewModel adopts `@Observable`.

### H2 — @ObservedObject in MainView
**File**: `App/Sources/MainView.swift:4`
`@ObservedObject var viewModel: AppViewModel` → `@Bindable var viewModel: AppViewModel` (for Toggle bindings) or plain `var viewModel: AppViewModel`.

### H3 — @ObservedObject in MenuBarPanelView
**File**: `App/Sources/MenuBarPanelView.swift:4`
`@ObservedObject var viewModel: AppViewModel` → `var viewModel: AppViewModel` (no bindings needed here).

### H4 — Timer.publish Combine pattern
**File**: `App/Sources/AppViewModel.swift:162-172`
`Timer.publish(every:on:in:).autoconnect().sink { ... }` → Swift Concurrency async loop:
```swift
Task { @MainActor in
    await updateBatteryLevel()
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(60))
        await updateBatteryLevel()
    }
}
```
Eliminates `import Combine`, `AnyCancellable?`, and nested `[weak self]` closures.

### H5 — withAnimation closure (modernizable)
**File**: `App/Sources/MainView.swift:48-51`
`withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) { isAnimating = true }` → replace with `TimelineView(.animation)` per performance audit H1.

### H6 — GCD asyncAfter in async context
**File**: `App/Sources/PowerDaemonClient.swift:207`
`DispatchQueue.global(qos:).asyncAfter(...)` for XPC timeout → cancellable `Task.sleep`-based timeout.

## LOW Issues

### L1 — XPC protocol completion handlers
**File**: `Shared/Sources/PowerHelperXPCProtocol.swift`
@objc XPC protocol requires completion handler callbacks. Lower priority — system-level interface constraint. Can be wrapped with Swift Concurrency adapters at the call site.

## Migration Prerequisites

1. **Migrate AppViewModel to @Observable** (C1) — ~15 minutes — prerequisite for all view migrations
2. **Update views** (H1-H3) — ~20 minutes — after model migration
3. **Modernize Timer** (H4) — ~10 minutes — remove Combine dependency
4. **Animation** (H5) + **GCD timeout** (H6) — ~10 minutes each
