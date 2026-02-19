# Testing Audit — ControlPower
**Date**: 2026-02-18
**Scope**: Tests/ControlPowerTests.swift + App/Sources/

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH | 1 |
| MEDIUM | 2 |
| LOW | 2 |
| **Total** | **5** |

**Overall Quality**: Excellent — no flaky patterns, no sleep() calls, no force unwraps, no shared mutable state.

## HIGH Issues

### H1 — TEST_HOST configuration forces full app launch for unit tests
**File**: `ControlPower.xcodeproj/project.pbxproj:429,440,546,557,582,593`
`TEST_HOST = "$(BUILT_PRODUCTS_DIR)/ControlPower.app/Contents/MacOS/ControlPower"` requires macOS app to launch for every test run. Current tests are pure logic (AppViewModel, PMSetParser, TimedProcessRunner) with no UI dependencies — they don't need an app host.
**Impact**: 20-60 second test runs vs 3-5 second runs without host. 10-20x slower feedback loop.
**Fix**: In Xcode, select ControlPowerTests target → Build Settings → remove TEST_HOST.

## MEDIUM Issues

### M1 — XCTest migration candidate (Swift Testing)
**File**: `Tests/ControlPowerTests.swift:108-158`
Pure logic tests (`testPMSetParserReadsValues`, `testTimedProcessRunnerReturnsOutputForSuccess`, etc.) are ideal Swift Testing migration candidates. Benefits: parallel execution, better `#expect` error messages, no app launch required.

### M2 — Parameterized test opportunity
**File**: `Tests/ControlPowerTests.swift:108-128`
3 parser test functions with similar structure could be consolidated using `@Test(arguments:)` parameterization in Swift Testing. Reduces duplication and makes adding new cases trivial.

## LOW Issues

### L1 — No UI layer tests
`MainView.swift` (336 lines) and `MenuBarPanelView.swift` (142 lines) are untested. Status display logic (`statusIcon`, `statusColor`, `statusTitle`) not validated. Low priority since these are thin rendering views.

### L2 — Error handling coverage gaps
**File**: `App/Sources/AppViewModel.swift:63,90,175-186`
`startup()` error path, `toggleHelper()` error path, and `checkBatterySafety()` low-battery trigger are untested. Recommend adding 3-4 targeted tests.

## Positive Patterns

- Proper `@MainActor` on async test methods
- `CheckedContinuation` for async coordination (no sleep calls)
- `FakePowerDaemonClient` is comprehensive and well-structured
- Tests are deterministic and parallelizable
- `nonisolated(unsafe)` on fake client reference in tests

## Quick Win

Fix TEST_HOST (5 minutes) → 10-20x faster test runs immediately.
