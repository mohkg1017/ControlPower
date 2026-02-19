import Foundation
import Synchronization
import XCTest
@testable import ControlPowerCore

final class ControlPowerTests: XCTestCase {
    @MainActor
    func testViewModelRefreshUpdatesStateFromInjectedClient() async {
        let client = FakePowerDaemonClient()
        client.fetchStatusResult = .success(
            PowerHelperStatus(
                snapshot: PMSetSnapshot(disableSleep: true, lidWake: false, summary: "mock-summary"),
                source: .helper
            )
        )

        let viewModel = AppViewModel(client: client)
        await viewModel.refreshStatus()

        XCTAssertEqual(viewModel.snapshot.disableSleep, true)
        XCTAssertEqual(viewModel.snapshot.lidWake, false)
        XCTAssertEqual(viewModel.snapshot.summary, "mock-summary")
        XCTAssertEqual(viewModel.statusSource, .helper)
        XCTAssertEqual(client.fetchStatusCallCount, 1)
    }

    @MainActor
    func testViewModelRefreshSkipsConcurrentRequests() async {
        let client = FakePowerDaemonClient()
        client.holdFetchStatus = true

        let viewModel = AppViewModel(client: client)

        async let firstRefresh: Void = viewModel.refreshStatus()
        await client.waitForFetchStatusCallCount(1)
        await viewModel.refreshStatus()
        client.resumeHeldFetchStatus()
        await firstRefresh

        XCTAssertEqual(client.fetchStatusCallCount, 1)
    }

    @MainActor
    func testViewModelMutationsRunSequentially() async {
        let client = FakePowerDaemonClient()

        let viewModel = AppViewModel(client: client)
        viewModel.toggleDisableSleep()
        viewModel.restoreDefaults()

        await client.waitForMutationCallCount(2)
        await client.waitForIdleMutations()

        XCTAssertEqual(client.setDisableSleepCallCount, 1)
        XCTAssertEqual(client.restoreDefaultsCallCount, 1)
        XCTAssertEqual(client.maxConcurrentMutationCalls, 1)
    }

    @MainActor
    func testToggleDisableSleepUsesCurrentSnapshotAsSourceOfTruth() async {
        let client = FakePowerDaemonClient()
        client.fetchStatusResult = .success(
            PowerHelperStatus(
                snapshot: PMSetSnapshot(disableSleep: false, lidWake: true, summary: "first"),
                source: .helper
            )
        )

        let viewModel = AppViewModel(client: client)
        await viewModel.refreshStatus()

        client.fetchStatusResult = .success(
            PowerHelperStatus(
                snapshot: PMSetSnapshot(disableSleep: true, lidWake: true, summary: "after-toggle"),
                source: .helper
            )
        )

        viewModel.toggleDisableSleep()
        await client.waitForMutationCallCount(1)
        await client.waitForFetchStatusCallCount(2)
        await client.waitForIdleMutations()
        await Task.yield()

        XCTAssertEqual(client.lastDisableSleepValue, true)
        XCTAssertEqual(viewModel.snapshot.disableSleep, true)
        XCTAssertEqual(viewModel.snapshot.summary, "after-toggle")
    }

    @MainActor
    func testRestoreDefaultsFailureSurfacesError() async {
        let client = FakePowerDaemonClient()
        client.restoreDefaultsResult = .failure(
            NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "restore failed"])
        )

        let viewModel = AppViewModel(client: client)
        viewModel.restoreDefaults()
        await client.waitForMutationCallCount(1)
        await client.waitForIdleMutations()
        for _ in 0..<20 where viewModel.lastError == nil {
            await Task.yield()
        }

        XCTAssertEqual(client.restoreDefaultsCallCount, 1)
        XCTAssertEqual(viewModel.lastError, "Restore defaults failed: restore failed")
    }

    @MainActor
    func testLowBatteryProtectionDisablesNoSleep() async {
        let client = FakePowerDaemonClient()
        client.fetchStatusResult = .success(
            PowerHelperStatus(
                snapshot: PMSetSnapshot(disableSleep: true, lidWake: true, summary: "awake"),
                source: .helper
            )
        )

        let viewModel = AppViewModel(client: client)
        viewModel.batteryLevel = 20
        await viewModel.refreshStatus()
        await client.waitForMutationCallCount(1)
        await client.waitForIdleMutations()

        XCTAssertEqual(client.setDisableSleepCallCount, 1)
        XCTAssertEqual(client.lastDisableSleepValue, false)
    }

    @MainActor
    func testLowBatteryProtectionDisabledSkipsAutoDisable() async {
        let client = FakePowerDaemonClient()
        client.fetchStatusResult = .success(
            PowerHelperStatus(
                snapshot: PMSetSnapshot(disableSleep: true, lidWake: true, summary: "awake"),
                source: .helper
            )
        )

        let viewModel = AppViewModel(client: client)
        viewModel.batteryLevel = 20
        viewModel.isLowBatteryProtectionEnabled = false
        await viewModel.refreshStatus()

        XCTAssertEqual(client.setDisableSleepCallCount, 0)
    }

    @MainActor
    func testRefreshStatusSanitizesErrorMessage() async {
        let client = FakePowerDaemonClient()
        let longLine = String(repeating: "x", count: 250)
        client.fetchStatusResult = .failure(
            NSError(
                domain: "Test",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "\(longLine)\nnew-line"]
            )
        )

        let viewModel = AppViewModel(client: client)
        await viewModel.refreshStatus()

        let message = viewModel.lastError ?? ""
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(message.contains("\n"))
        XCTAssertLessThanOrEqual(message.count, "Refresh status failed: ".count + 200)
    }

    @MainActor
    func testToggleHelperSuccessRefreshesStatus() async {
        let client = FakePowerDaemonClient()
        client.fetchStatusResult = .success(
            PowerHelperStatus(
                snapshot: PMSetSnapshot(disableSleep: false, lidWake: true, summary: "after-toggle-helper"),
                source: .helper
            )
        )

        let viewModel = AppViewModel(client: client)
        viewModel.toggleHelper()
        await client.waitForFetchStatusCallCount(1)
        await Task.yield()

        XCTAssertEqual(client.fetchStatusCallCount, 1)
        XCTAssertEqual(viewModel.isHelperEnabled, false)
        XCTAssertEqual(viewModel.snapshot.summary, "after-toggle-helper")
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testToggleHelperFailureSurfacesErrorAndSkipsRefresh() async {
        let client = FakePowerDaemonClient()
        client.setHelperEnabledShouldFail = true

        let viewModel = AppViewModel(client: client)
        viewModel.toggleHelper()
        await Task.yield()

        XCTAssertEqual(client.fetchStatusCallCount, 0)
        XCTAssertEqual(viewModel.isHelperEnabled, true)
        XCTAssertEqual(viewModel.lastError, "Failed to disable helper: approval missing")
    }

    @MainActor
    func testStartupSkipsRegistrationAndRefreshInTestEnvironment() async {
        let client = FakePowerDaemonClient()
        let viewModel = AppViewModel(client: client, isTestEnvironment: true)
        viewModel.startup()
        await Task.yield()

        XCTAssertEqual(client.registerDaemonCallCount, 0)
        XCTAssertEqual(client.fetchStatusCallCount, 0)
    }

    @MainActor
    func testStartupRegistersAndRefreshesOutsideTestEnvironment() async {
        let client = FakePowerDaemonClient()
        client.fetchStatusResult = .success(
            PowerHelperStatus(
                snapshot: PMSetSnapshot(disableSleep: true, lidWake: true, summary: "startup"),
                source: .helper
            )
        )

        let viewModel = AppViewModel(client: client, isTestEnvironment: false)
        viewModel.startup()
        await client.waitForFetchStatusCallCount(1)
        await Task.yield()

        XCTAssertEqual(client.registerDaemonCallCount, 1)
        XCTAssertEqual(client.fetchStatusCallCount, 1)
        XCTAssertEqual(viewModel.snapshot.summary, "startup")

        viewModel.startup()
        await Task.yield()
        XCTAssertEqual(client.registerDaemonCallCount, 1)
        XCTAssertEqual(client.fetchStatusCallCount, 1)
    }

    @MainActor
    func testStartupStillRefreshesWhenRegisterFailsOutsideTestEnvironment() async {
        let client = FakePowerDaemonClient()
        client.registerDaemonResult = .failure(
            NSError(domain: "Test", code: 11, userInfo: [NSLocalizedDescriptionKey: "register failed"])
        )
        client.fetchStatusResult = .success(
            PowerHelperStatus(
                snapshot: PMSetSnapshot(disableSleep: false, lidWake: true, summary: "after-failed-register"),
                source: .localFallback
            )
        )

        let viewModel = AppViewModel(client: client, isTestEnvironment: false)
        viewModel.startup()
        await client.waitForFetchStatusCallCount(1)
        await Task.yield()

        XCTAssertEqual(client.registerDaemonCallCount, 1)
        XCTAssertEqual(client.fetchStatusCallCount, 1)
        XCTAssertEqual(viewModel.snapshot.summary, "after-failed-register")
    }

    @MainActor
    func testStartupShowsRegisterErrorUntilRefreshCompletes() async {
        let client = FakePowerDaemonClient()
        client.registerDaemonResult = .failure(
            NSError(domain: "Test", code: 12, userInfo: [NSLocalizedDescriptionKey: "approval required"])
        )
        client.holdFetchStatus = true

        let viewModel = AppViewModel(client: client, isTestEnvironment: false)
        viewModel.startup()
        await client.waitForFetchStatusCallCount(1)

        XCTAssertEqual(viewModel.lastError, "approval required")

        client.resumeHeldFetchStatus()
        await Task.yield()
    }

    @MainActor
    func testTimerZeroMinutesDisablesNoSleepWhenActive() async {
        let client = FakePowerDaemonClient()
        let viewModel = AppViewModel(client: client)
        viewModel.snapshot = PMSetSnapshot(disableSleep: true, lidWake: true, summary: "awake")

        viewModel.startTimer(minutes: 0)
        await client.waitForMutationCallCount(1)
        await client.waitForIdleMutations()
        await Task.yield()

        XCTAssertEqual(client.lastDisableSleepValue, false)
        XCTAssertNil(viewModel.remainingSeconds)
    }

    func testTimedProcessRunnerReturnsOutputForSuccess() {
        let runner = TimedProcessRunner(executableURL: URL(fileURLWithPath: "/bin/echo"), timeoutSeconds: 1)
        let result = runner.run(arguments: ["hello"])
        XCTAssertTrue(result.success)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.output, "hello")
    }

    func testTimedProcessRunnerTimesOutProcess() {
        let runner = TimedProcessRunner(executableURL: URL(fileURLWithPath: "/bin/sleep"), timeoutSeconds: 0.2)
        let result = runner.run(arguments: ["2"])
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.timedOut)
    }

    func testClientAuthorizationPolicyRejectsMismatchedBundleIdentifier() {
        let policy = ClientAuthorizationPolicy(bundleIdentifier: "com.moe.controlpower", teamIdentifier: "TEAM123")

        XCTAssertFalse(policy.isAuthorizedClient(bundleIdentifier: "com.other.app", teamIdentifier: "TEAM123"))
    }

    func testClientAuthorizationPolicyRequiresTeamIdentifierWhenConfigured() {
        let policy = ClientAuthorizationPolicy(bundleIdentifier: "com.moe.controlpower", teamIdentifier: "TEAM123")

        XCTAssertTrue(policy.isAuthorizedClient(bundleIdentifier: "com.moe.controlpower", teamIdentifier: "TEAM123"))
        XCTAssertFalse(policy.isAuthorizedClient(bundleIdentifier: "com.moe.controlpower", teamIdentifier: "TEAM999"))
        XCTAssertFalse(policy.isAuthorizedClient(bundleIdentifier: "com.moe.controlpower", teamIdentifier: nil))
    }

    func testClientAuthorizationPolicyRejectsClientWhenTeamIdentifierUnavailable() {
        let policy = ClientAuthorizationPolicy(bundleIdentifier: "com.moe.controlpower", teamIdentifier: nil)

        XCTAssertFalse(policy.isAuthorizedClient(bundleIdentifier: "com.moe.controlpower", teamIdentifier: nil))
        XCTAssertFalse(policy.isAuthorizedClient(bundleIdentifier: "com.moe.controlpower", teamIdentifier: "TEAM123"))
    }

    func testXPCReplyGateCancelsInstalledTimeoutTask() async throws {
        let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            let gate = XPCReplyGate(continuation: continuation) {}
            let timeoutTask = Task<Void, Never> {
                try? await Task.sleep(for: .seconds(5))
            }

            gate.installTimeoutTask(timeoutTask)
            gate.finish(.success(42))

            XCTAssertTrue(timeoutTask.isCancelled)
        }

        XCTAssertEqual(value, 42)
    }

    func testXPCReplyGateResumesContinuationOnlyOnce() async throws {
        let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            let gate = XPCReplyGate(continuation: continuation) {}

            gate.finish(.success(1))
            gate.finish(.success(2))
        }

        XCTAssertEqual(value, 1)
    }

    @MainActor
    func testTimerNegativeMinutesClampsToZeroAndDisablesNoSleepWhenActive() async {
        let client = FakePowerDaemonClient()
        let viewModel = AppViewModel(client: client)
        viewModel.snapshot = PMSetSnapshot(disableSleep: true, lidWake: true, summary: "awake")

        viewModel.startTimer(minutes: -5)
        await client.waitForMutationCallCount(1)
        await client.waitForIdleMutations()
        await Task.yield()

        XCTAssertEqual(viewModel.selectedDurationMinutes, 0)
        XCTAssertNil(viewModel.remainingSeconds)
        XCTAssertEqual(client.lastDisableSleepValue, false)
    }
}

private final class FakePowerDaemonClient: PowerDaemonClientProtocol, Sendable {
    private struct State {
        var registerDaemonResult: Result<Void, Error> = .success(())
        var fetchStatusResult: Result<PowerHelperStatus, Error> = .success(
            PowerHelperStatus(
                snapshot: PMSetSnapshot(disableSleep: nil, lidWake: nil, summary: "default"),
                source: .localFallback
            )
        )
        var helperEnabled = true
        var setHelperEnabledShouldFail = false
        var holdFetchStatus = false
        var restoreDefaultsResult: Result<Void, Error> = .success(())
        var registerDaemonCallCount = 0
        var fetchStatusCallCount = 0
        var setDisableSleepCallCount = 0
        var restoreDefaultsCallCount = 0
        var maxConcurrentMutationCalls = 0
        var lastDisableSleepValue: Bool?
        var activeMutationCalls = 0
        var fetchStatusCountWait: (expected: Int, continuation: CheckedContinuation<Void, Never>)?
        var mutationCountWait: (expected: Int, continuation: CheckedContinuation<Void, Never>)?
        var idleMutationWait: CheckedContinuation<Void, Never>?
        var heldFetchStatusContinuation: CheckedContinuation<Void, Never>?

        var totalMutationCallCount: Int {
            setDisableSleepCallCount + restoreDefaultsCallCount
        }
    }

    private let state = Mutex(State())

    var registerDaemonResult: Result<Void, Error> {
        get { state.withLock { $0.registerDaemonResult } }
        set { state.withLock { $0.registerDaemonResult = newValue } }
    }

    var fetchStatusResult: Result<PowerHelperStatus, Error> {
        get { state.withLock { $0.fetchStatusResult } }
        set { state.withLock { $0.fetchStatusResult = newValue } }
    }

    var helperEnabled: Bool {
        get { state.withLock { $0.helperEnabled } }
        set { state.withLock { $0.helperEnabled = newValue } }
    }

    var setHelperEnabledShouldFail: Bool {
        get { state.withLock { $0.setHelperEnabledShouldFail } }
        set { state.withLock { $0.setHelperEnabledShouldFail = newValue } }
    }

    var holdFetchStatus: Bool {
        get { state.withLock { $0.holdFetchStatus } }
        set { state.withLock { $0.holdFetchStatus = newValue } }
    }

    var restoreDefaultsResult: Result<Void, Error> {
        get { state.withLock { $0.restoreDefaultsResult } }
        set { state.withLock { $0.restoreDefaultsResult = newValue } }
    }

    var fetchStatusCallCount: Int { state.withLock { $0.fetchStatusCallCount } }
    var registerDaemonCallCount: Int { state.withLock { $0.registerDaemonCallCount } }
    var setDisableSleepCallCount: Int { state.withLock { $0.setDisableSleepCallCount } }
    var restoreDefaultsCallCount: Int { state.withLock { $0.restoreDefaultsCallCount } }
    var maxConcurrentMutationCalls: Int { state.withLock { $0.maxConcurrentMutationCalls } }
    var lastDisableSleepValue: Bool? { state.withLock { $0.lastDisableSleepValue } }

    func registerDaemonIfNeeded() throws {
        let result = state.withLock { state in
            state.registerDaemonCallCount += 1
            return state.registerDaemonResult
        }
        try result.get()
    }

    func isHelperEnabled() -> Bool {
        state.withLock { $0.helperEnabled }
    }

    func setHelperEnabled(_ enabled: Bool) throws {
        let shouldFail = state.withLock { $0.setHelperEnabledShouldFail }
        if shouldFail {
            throw FakePowerDaemonClientError.approvalMissing
        }
        state.withLock { $0.helperEnabled = enabled }
    }

    @MainActor
    func waitForFetchStatusCallCount(_ expected: Int) async {
        if state.withLock({ $0.fetchStatusCallCount >= expected }) {
            return
        }
        await withCheckedContinuation { continuation in
            let shouldResumeNow = state.withLock { state in
                if state.fetchStatusCallCount >= expected {
                    return true
                }
                state.fetchStatusCountWait = (expected, continuation)
                return false
            }
            if shouldResumeNow {
                continuation.resume()
            }
        }
    }

    @MainActor
    func waitForMutationCallCount(_ expected: Int) async {
        if state.withLock({ $0.totalMutationCallCount >= expected }) {
            return
        }
        await withCheckedContinuation { continuation in
            let shouldResumeNow = state.withLock { state in
                if state.totalMutationCallCount >= expected {
                    return true
                }
                state.mutationCountWait = (expected, continuation)
                return false
            }
            if shouldResumeNow {
                continuation.resume()
            }
        }
    }

    @MainActor
    func waitForIdleMutations() async {
        if state.withLock({ $0.activeMutationCalls == 0 }) {
            return
        }
        await withCheckedContinuation { continuation in
            let shouldResumeNow = state.withLock { state in
                if state.activeMutationCalls == 0 {
                    return true
                }
                state.idleMutationWait = continuation
                return false
            }
            if shouldResumeNow {
                continuation.resume()
            }
        }
    }

    func resumeHeldFetchStatus() {
        let continuation = state.withLock { state in
            let continuation = state.heldFetchStatusContinuation
            state.heldFetchStatusContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    func fetchStatus() async throws -> PowerHelperStatus {
        let (shouldHold, waitContinuation) = state.withLock { state in
            state.fetchStatusCallCount += 1
            let waitContinuation: CheckedContinuation<Void, Never>?
            if let wait = state.fetchStatusCountWait, state.fetchStatusCallCount >= wait.expected {
                waitContinuation = wait.continuation
                state.fetchStatusCountWait = nil
            } else {
                waitContinuation = nil
            }
            return (state.holdFetchStatus, waitContinuation)
        }
        waitContinuation?.resume()

        if shouldHold {
            await withCheckedContinuation { continuation in
                state.withLock { $0.heldFetchStatusContinuation = continuation }
            }
        }

        return try state.withLock { state in
            try state.fetchStatusResult.get()
        }
    }

    func setDisableSleep(_ enabled: Bool) async throws {
        let waitContinuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.lastDisableSleepValue = enabled
            state.setDisableSleepCallCount += 1
            if let wait = state.mutationCountWait, state.totalMutationCallCount >= wait.expected {
                state.mutationCountWait = nil
                return wait.continuation
            }
            return nil
        }
        waitContinuation?.resume()
        await withMutationTracking()
    }

    func restoreDefaults() async throws {
        let (waitContinuation, result) = state.withLock { state in
            state.restoreDefaultsCallCount += 1
            let waitContinuation: CheckedContinuation<Void, Never>?
            if let wait = state.mutationCountWait, state.totalMutationCallCount >= wait.expected {
                state.mutationCountWait = nil
                waitContinuation = wait.continuation
            } else {
                waitContinuation = nil
            }
            return (waitContinuation, state.restoreDefaultsResult)
        }
        waitContinuation?.resume()
        await withMutationTracking()
        try result.get()
    }

    private func withMutationTracking() async {
        state.withLock { state in
            state.activeMutationCalls += 1
            if state.activeMutationCalls > state.maxConcurrentMutationCalls {
                state.maxConcurrentMutationCalls = state.activeMutationCalls
            }
        }

        await Task.yield()

        let idleContinuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.activeMutationCalls -= 1
            guard state.activeMutationCalls == 0 else {
                return nil
            }
            let continuation = state.idleMutationWait
            state.idleMutationWait = nil
            return continuation
        }
        idleContinuation?.resume()
    }
}

private enum FakePowerDaemonClientError: LocalizedError, Sendable {
    case approvalMissing

    var errorDescription: String? {
        switch self {
        case .approvalMissing:
            return "approval missing"
        }
    }
}
