# SwiftUI Performance Audit — ControlPower
**Date**: 2026-02-18
**Scope**: App/Sources/
**Risk Score**: 4.0/10 (small utility app, no large lists or image processing)

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH | 1 |
| MEDIUM | 4 |
| LOW | 1 |
| **Total** | **6** |

## HIGH Issues

### H1 — Perpetual MeshGradient animation drives 60fps redraws of full detail pane
**File**: `App/Sources/MainView.swift:48-51, 262-278`
`onAppear` starts an infinite `withAnimation(.easeInOut(duration:4).repeatForever(autoreverses:true))` toggling `isAnimating`. This drives `MeshGradient` control-point interpolation + `.blur(radius:40)` on every animation frame (~60fps). The blur is re-computed via Metal on every frame. The animated state propagates invalidation to the full detail pane `ZStack`.
**Fix**: Replace with `TimelineView(.animation)` to isolate animation to that sub-tree without contaminating `isAnimating` state. Or: reduce blur to `radius:20`, slow animation to `duration:8` — halves GPU cost.

## MEDIUM Issues

### M1 — ObservableObject over-broadcasts on every @Published change
**File**: `App/Sources/AppViewModel.swift:12-26`
8 `@Published` properties. `remainingSeconds` ticks every second, causing full re-render of both `MainView` and `MenuBarPanelView` via `objectWillChange` broadcast even when `MenuBarPanelView` doesn't read `remainingSeconds`. With `@Observable`, views only re-render when their specifically-accessed properties change.
**Fix**: Migrate to `@Observable` macro (see architecture audit H1).

### M2 — sourceText() method call in view body
**File**: `App/Sources/MenuBarPanelView.swift:62`
`Text(viewModel.sourceText())` — method call rather than property access. Called on every render including unnecessary 1-second timer ticks. Negligible in isolation but part of the over-broadcast pattern.
**Fix**: Convert to computed property `var sourceText: String`.

### M3 — batteryCheckTimer AnyCancellable lacks lifecycle cleanup
**File**: `App/Sources/AppViewModel.swift:27, 162-172`
No explicit teardown path. If reassigned, old timer is silently cancelled without logging. Precedent for timer-leaking patterns in future.
**Fix**: Add `invalidate()` method and a `deinit` cancelling both timers.

### M4 — Inline Binding(get:set:) re-allocated every render
**Files**: `App/Sources/MenuBarPanelView.swift:69-73`, `App/Sources/MainView.swift:103-106`
Custom `Binding` closures constructed on every view body evaluation. Minor allocation overhead.
**Fix**: Extract to computed properties outside `body`.

## LOW Issues

### L1 — ObservableObject pattern (subsumed by M1 migration)
All four files use the pre-iOS-17 observation stack. Resolved by `@Observable` migration.

## Confirmed Non-Issues
- No DateFormatter/NumberFormatter in view body
- No Data(contentsOf:) in view body
- No image processing in views
- No large collections without lazy loading
- ForEach uses static small collections with id: \.self (correct)

## Recommended Actions
1. Fix H1 (TimelineView isolation) — stops 60fps full-pane invalidation
2. Fix M1 (@Observable migration) — eliminates 1-second full re-renders
3. Fix M3 (add deinit/invalidate) — correctness for future refactors
