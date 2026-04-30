import Foundation
import ServiceManagement
import Synchronization
import XCTest
@testable import ControlPowerCore

nonisolated final class ControlPowerTests: XCTestCase {
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
    func testMutationQueueCoalescesRapidDisableSleepMutations() async {
        let client = FakePowerDaemonClient()
        client.holdFetchStatus = true
        let viewModel = AppViewModel(client: client)

        viewModel.toggleDisableSleep()
        await client.waitForMutationCallCount(1)

        for _ in 0..<80 {
            viewModel.toggleDisableSleep()
        }

        XCTAssertNotEqual(
            viewModel.lastError,
            "Too many pending actions. Please wait for current changes to finish."
        )

        client.holdFetchStatus = false
        client.resumeHeldFetchStatus()
        await client.waitForIdleMutations()

        XCTAssertLessThanOrEqual(client.setDisableSleepCallCount, 2)
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
        await waitForCondition {
            client.lastDisableSleepValue == true && viewModel.snapshot.summary == "after-toggle"
        }

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
        await waitForCondition { viewModel.lastError != nil }

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
    func testEnablingLowBatteryProtectionImmediatelyEnforcesSafety() async {
        let client = FakePowerDaemonClient()
        let viewModel = AppViewModel(client: client, isTestEnvironment: true)
        viewModel.snapshot = PMSetSnapshot(disableSleep: true, lidWake: true, summary: "awake")
        viewModel.batteryLevel = 15
        viewModel.isLowBatteryProtectionEnabled = false

        viewModel.isLowBatteryProtectionEnabled = true
        await client.waitForMutationCallCount(1)
        await client.waitForIdleMutations()

        XCTAssertEqual(client.setDisableSleepCallCount, 1)
        XCTAssertEqual(client.lastDisableSleepValue, false)
    }

    @MainActor
    func testLowBatteryProtectionDefaultsEnabledInTestEnvironment() async {
        let client = FakePowerDaemonClient()
        let viewModel = AppViewModel(client: client, isTestEnvironment: true)
        XCTAssertTrue(viewModel.isLowBatteryProtectionEnabled)
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
    func testRefreshFailureClearsHelperRepairFlagWhenDaemonHealthy() async {
        let client = FakePowerDaemonClient()
        client.helperEnabled = true
        client.daemonBroken = false
        client.fetchStatusResult = .failure(
            NSError(domain: "Test", code: 201, userInfo: [NSLocalizedDescriptionKey: "refresh failed"])
        )

        let viewModel = AppViewModel(client: client)
        viewModel.helperNeedsRepair = true

        await viewModel.refreshStatus()

        XCTAssertFalse(viewModel.helperNeedsRepair)
        XCTAssertEqual(viewModel.lastError, "Refresh status failed: refresh failed")
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
        await waitForCondition { viewModel.snapshot.summary == "after-toggle-helper" }

        XCTAssertEqual(client.fetchStatusCallCount, 1)
        XCTAssertEqual(viewModel.isHelperEnabled, false)
        XCTAssertEqual(viewModel.snapshot.summary, "after-toggle-helper")
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testSetHelperEnabledNoOpWhenStateUnchanged() async {
        let client = FakePowerDaemonClient()
        let viewModel = AppViewModel(client: client)

        viewModel.setHelperEnabled(true)

        XCTAssertEqual(client.fetchStatusCallCount, 0)
        XCTAssertEqual(viewModel.isHelperEnabled, true)
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testSetHelperEnabledProcessesLatestQueuedIntent() async {
        let client = FakePowerDaemonClient()
        client.holdFetchStatus = true
        client.fetchStatusResult = .success(
            PowerHelperStatus(
                snapshot: PMSetSnapshot(disableSleep: false, lidWake: true, summary: "queued-intent"),
                source: .helper
            )
        )

        let viewModel = AppViewModel(client: client)
        viewModel.setHelperEnabled(false)
        await client.waitForSetHelperEnabledCallCount(1)
        await client.waitForFetchStatusCallCount(1)

        viewModel.setHelperEnabled(true)
        client.holdFetchStatus = false
        client.resumeHeldFetchStatus()

        await client.waitForSetHelperEnabledCallCount(2)
        await client.waitForIdleMutations()
        await waitForCondition { client.helperEnabled && viewModel.isHelperEnabled }

        XCTAssertTrue(client.helperEnabled)
        XCTAssertTrue(viewModel.isHelperEnabled)
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testSetHelperEnabledReappliesDesiredNoSleepAfterEnable() async {
        let client = FakePowerDaemonClient()
        client.daemonStatus = .disabled
        client.fetchStatusResult = .success(
            PowerHelperStatus(
                snapshot: PMSetSnapshot(disableSleep: true, lidWake: true, summary: "before-enable"),
                source: .helper
            )
        )

        let viewModel = AppViewModel(client: client, isTestEnvironment: true)
        viewModel.setDisableSleepEnabled(true)
        await client.waitForMutationCallCount(1)
        await client.waitForIdleMutations()
        client.fetchStatusResult = .success(
            PowerHelperStatus(
                snapshot: PMSetSnapshot(disableSleep: false, lidWake: true, summary: "after-enable"),
                source: .helper
            )
        )

        viewModel.setHelperEnabled(true)
        await waitForCondition { client.lastDisableSleepValue == true }
        await client.waitForMutationCallCount(2)
        await client.waitForIdleMutations()

        XCTAssertEqual(client.setHelperEnabledCallCount, 1)
        XCTAssertEqual(client.setDisableSleepCallCount, 2)
        XCTAssertEqual(client.lastDisableSleepValue, true)
    }

    @MainActor
    func testToggleHelperRefreshFailureSurfacesRefreshErrorAndKeepsStateConsistent() async {
        let client = FakePowerDaemonClient()
        client.fetchStatusResult = .failure(
            NSError(domain: "Test", code: 2, userInfo: [NSLocalizedDescriptionKey: "fetch failed"])
        )

        let viewModel = AppViewModel(client: client)
        viewModel.helperNeedsRepair = true
        viewModel.toggleHelper()
        await waitForCondition { viewModel.lastError != nil }

        XCTAssertEqual(client.setHelperEnabledCallCount, 1)
        XCTAssertEqual(client.fetchStatusCallCount, 1)
        XCTAssertFalse(viewModel.isHelperEnabled)
        XCTAssertFalse(viewModel.helperNeedsRepair)
        XCTAssertEqual(viewModel.lastError, "Helper was disabled, but status refresh failed: fetch failed")
    }

    @MainActor
    func testToggleHelperFailureSurfacesErrorAndSkipsRefresh() async {
        let client = FakePowerDaemonClient()
        client.setHelperEnabledShouldFail = true

        let viewModel = AppViewModel(client: client)
        viewModel.toggleHelper()
        await waitForCondition { viewModel.lastError != nil }

        XCTAssertEqual(client.fetchStatusCallCount, 0)
        XCTAssertEqual(viewModel.isHelperEnabled, true)
        XCTAssertEqual(viewModel.lastError, "Failed to disable helper: approval missing")
    }

    @MainActor
    func testSetHelperEnabledKeepsLatestQueuedIntent() async {
        let client = FakePowerDaemonClient()
        client.fetchStatusResult = .success(
            PowerHelperStatus(
                snapshot: PMSetSnapshot(disableSleep: false, lidWake: true, summary: "queued-helper-update"),
                source: .helper
            )
        )
        client.holdFetchStatus = true

        let viewModel = AppViewModel(client: client)
        viewModel.setHelperEnabled(false)
        await client.waitForFetchStatusCallCount(1)

        viewModel.setHelperEnabled(true)

        client.resumeHeldFetchStatus()
        await client.waitForFetchStatusCallCount(2)
        client.resumeHeldFetchStatus()
        await waitForCondition { viewModel.isHelperEnabled == true && client.helperEnabled == true }

        XCTAssertEqual(client.fetchStatusCallCount, 2)
        XCTAssertTrue(viewModel.isHelperEnabled)
        XCTAssertTrue(client.helperEnabled)
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testToggleHelperRefreshFailureReportsRefreshSpecificError() async {
        let client = FakePowerDaemonClient()
        client.fetchStatusResult = .failure(
            NSError(domain: "Test", code: 22, userInfo: [NSLocalizedDescriptionKey: "status fetch failed"])
        )

        let viewModel = AppViewModel(client: client)
        viewModel.toggleHelper()
        await waitForCondition { viewModel.lastError != nil && viewModel.isHelperEnabled == false }

        XCTAssertEqual(
            viewModel.lastError,
            "Helper was disabled, but status refresh failed: status fetch failed"
        )
        XCTAssertFalse(viewModel.isHelperEnabled)
        XCTAssertFalse(client.helperEnabled)
    }

    @MainActor
    func testToggleHelperRefreshFailureRecomputesHelperRepairState() async {
        let client = FakePowerDaemonClient()
        client.fetchStatusResult = .failure(
            NSError(domain: "Test", code: 23, userInfo: [NSLocalizedDescriptionKey: "refresh failed"])
        )

        let viewModel = AppViewModel(client: client)
        viewModel.statusSource = .localFallback
        viewModel.helperNeedsRepair = true

        viewModel.toggleHelper()
        await waitForCondition { viewModel.lastError != nil && viewModel.isHelperEnabled == false }

        XCTAssertFalse(viewModel.helperNeedsRepair)
    }

    @MainActor
    func testStartupSkipsRegistrationAndRefreshInTestEnvironment() async {
        let client = FakePowerDaemonClient()
        let viewModel = AppViewModel(client: client, isTestEnvironment: true)
        viewModel.startup()

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
        await waitForCondition { viewModel.snapshot.summary == "startup" }

        XCTAssertEqual(client.registerDaemonCallCount, 1)
        XCTAssertEqual(client.fetchStatusCallCount, 1)
        XCTAssertEqual(viewModel.snapshot.summary, "startup")

        viewModel.startup()
        XCTAssertEqual(client.registerDaemonCallCount, 1)
        XCTAssertEqual(client.fetchStatusCallCount, 1)
    }

    @MainActor
    func testStartupAutoRepairsAfterRegisterFailureWhenFallbackStatusRequiresIt() async {
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
        await client.waitForFetchStatusCallCount(2)
        await waitForCondition { viewModel.snapshot.summary == "after-failed-register" }

        XCTAssertEqual(client.registerDaemonCallCount, 1)
        XCTAssertEqual(client.fetchStatusCallCount, 2)
        XCTAssertEqual(client.repairDaemonCallCount, 1)
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
    }

    @MainActor
    func testStartupReappliesWhenDesiredNoSleepPersistedAndActualOff() async {
        let client = FakePowerDaemonClient()
        client.fetchStatusResult = .success(
            PowerHelperStatus(
                snapshot: PMSetSnapshot(disableSleep: false, lidWake: true, summary: "startup-off"),
                source: .helper
            )
        )

        let viewModel = AppViewModel(client: client, isTestEnvironment: false)
        viewModel.setDisableSleepEnabled(true)
        await client.waitForMutationCallCount(1)
        await client.waitForIdleMutations()

        let setCountBeforeStartup = client.setDisableSleepCallCount
        viewModel.startup()
        await client.waitForMutationCallCount(setCountBeforeStartup + 1)
        await client.waitForIdleMutations()

        XCTAssertEqual(client.setDisableSleepCallCount, setCountBeforeStartup + 1)
        XCTAssertEqual(client.lastDisableSleepValue, true)
    }

    @MainActor
    func testStartupSkipsReapplyWhenHelperNeedsRepair() async {
        let client = FakePowerDaemonClient()
        client.daemonBroken = true
        client.repairDaemonResult = .failure(FakePowerDaemonClientError.repairFailed)
        client.fetchStatusResult = .success(
            PowerHelperStatus(
                snapshot: PMSetSnapshot(disableSleep: false, lidWake: true, summary: "needs-repair"),
                source: .localFallback
            )
        )

        let viewModel = AppViewModel(client: client, isTestEnvironment: false)
        viewModel.setDisableSleepEnabled(true)
        await client.waitForMutationCallCount(1)
        await client.waitForIdleMutations()

        let fetchCountBeforeStartup = client.fetchStatusCallCount
        let setCountBeforeStartup = client.setDisableSleepCallCount
        viewModel.startup()
        await client.waitForRepairCallCount(1)
        await client.waitForFetchStatusCallCount(fetchCountBeforeStartup + 2)

        XCTAssertEqual(client.setDisableSleepCallCount, setCountBeforeStartup)
        XCTAssertTrue(viewModel.helperNeedsRepair)
    }

    @MainActor
    func testStartupSkipsReapplyWhenActualAlreadyOn() async {
        let client = FakePowerDaemonClient()
        client.fetchStatusResult = .success(
            PowerHelperStatus(
                snapshot: PMSetSnapshot(disableSleep: true, lidWake: true, summary: "already-on"),
                source: .helper
            )
        )

        let viewModel = AppViewModel(client: client, isTestEnvironment: false)
        viewModel.setDisableSleepEnabled(true)
        await client.waitForMutationCallCount(1)
        await client.waitForIdleMutations()

        let fetchCountBeforeStartup = client.fetchStatusCallCount
        let setCountBeforeStartup = client.setDisableSleepCallCount
        viewModel.startup()
        await client.waitForFetchStatusCallCount(fetchCountBeforeStartup + 1)

        XCTAssertEqual(client.setDisableSleepCallCount, setCountBeforeStartup)
    }

    @MainActor
    func testStatusShowsReapplyingNoSleepWhenDesiredAndActualDisagree() async {
        let client = FakePowerDaemonClient()
        client.fetchStatusResult = .success(
            PowerHelperStatus(
                snapshot: PMSetSnapshot(disableSleep: true, lidWake: true, summary: "enabled"),
                source: .helper
            )
        )

        let viewModel = AppViewModel(client: client, isTestEnvironment: true)
        viewModel.setDisableSleepEnabled(true)
        await client.waitForMutationCallCount(1)
        await client.waitForIdleMutations()
        viewModel.snapshot = PMSetSnapshot(disableSleep: false, lidWake: true, summary: "drifted")

        XCTAssertTrue(viewModel.isReapplyingNoSleep)
        XCTAssertEqual(viewModel.statusTitle, "Re-applying No Sleep…")
    }

    @MainActor
    func testTimerZeroMinutesDisablesNoSleepWhenActive() async {
        let client = FakePowerDaemonClient()
        let viewModel = AppViewModel(client: client)
        viewModel.snapshot = PMSetSnapshot(disableSleep: true, lidWake: true, summary: "awake")

        viewModel.startTimer(minutes: 0)
        await client.waitForMutationCallCount(1)
        await client.waitForIdleMutations()

        XCTAssertEqual(client.lastDisableSleepValue, false)
        XCTAssertFalse(viewModel.isTimerActive)
    }

    @MainActor
    func testTimerZeroMinutesQueuesDisableAfterPendingEnableWhenStartingOff() async {
        let client = FakePowerDaemonClient()
        let viewModel = AppViewModel(client: client)
        viewModel.snapshot = PMSetSnapshot(disableSleep: false, lidWake: true, summary: "normal")

        viewModel.startTimer(minutes: 0)
        await client.waitForMutationCallCount(1)
        await waitForCondition { client.lastDisableSleepValue == false }
        await client.waitForIdleMutations()

        XCTAssertGreaterThanOrEqual(client.setDisableSleepCallCount, 1)
        XCTAssertEqual(client.lastDisableSleepValue, false)
    }

    @MainActor
    func testStartTimerDoesNotActivateWhenEnableNoSleepFails() async {
        let client = FakePowerDaemonClient()
        client.setDisableSleepResult = .failure(FakePowerDaemonClientError.setDisableSleepFailed)

        let viewModel = AppViewModel(client: client)
        viewModel.snapshot = PMSetSnapshot(disableSleep: false, lidWake: true, summary: "normal")

        viewModel.startTimer(minutes: 30)
        await client.waitForMutationCallCount(1)
        await client.waitForIdleMutations()
        await waitForCondition { viewModel.lastError != nil }

        XCTAssertFalse(viewModel.isTimerActive)
        XCTAssertNil(viewModel.activeTimerEndDate)
        XCTAssertEqual(
            viewModel.lastError,
            "Start timer failed: set disable sleep failed"
        )
    }

    @MainActor
    func testStartTimerWhenAlreadyAwakeSetsDesiredNoSleep() async {
        let client = FakePowerDaemonClient()
        let viewModel = AppViewModel(client: client, isTestEnvironment: true)
        viewModel.snapshot = PMSetSnapshot(disableSleep: true, lidWake: true, summary: "awake")

        viewModel.startTimer(minutes: 30)

        XCTAssertTrue(viewModel.isTimerActive)
        XCTAssertTrue(viewModel.desiredNoSleep)
    }

    @MainActor
    func testDisablingNoSleepCancelsTimerEvenWhenSnapshotAlreadyOff() async {
        let client = FakePowerDaemonClient()
        let viewModel = AppViewModel(client: client, isTestEnvironment: true)
        viewModel.snapshot = PMSetSnapshot(disableSleep: true, lidWake: true, summary: "awake")

        viewModel.startTimer(minutes: 30)
        XCTAssertTrue(viewModel.isTimerActive)

        viewModel.snapshot = PMSetSnapshot(disableSleep: false, lidWake: true, summary: "off")
        viewModel.setDisableSleepEnabled(false)

        XCTAssertFalse(viewModel.isTimerActive)
        XCTAssertNil(viewModel.activeTimerEndDate)
        XCTAssertEqual(client.setDisableSleepCallCount, 0)
    }

    @MainActor
    func testTimerLoopInTestEnvironmentDoesNotRequireNSApplication() async {
        let client = FakePowerDaemonClient()
        let viewModel = AppViewModel(client: client, isTestEnvironment: true)
        viewModel.snapshot = PMSetSnapshot(disableSleep: true, lidWake: true, summary: "awake")

        viewModel.startTimer(minutes: 1)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(viewModel.isTimerActive)
        viewModel.cancelTimer()
        XCTAssertFalse(viewModel.isTimerActive)
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

    func testTimedProcessRunnerCancelsProcess() async {
        let runner = TimedProcessRunner(executableURL: URL(fileURLWithPath: "/bin/sleep"), timeoutSeconds: 10)
        let cancellation = TimedProcessCancellation()
        let (startedStream, startedContinuation) = AsyncStream.makeStream(of: Void.self)

        let task = Task.detached(priority: .utility) {
            runner.run(arguments: ["5"], cancellation: cancellation) {
                startedContinuation.yield()
                startedContinuation.finish()
            }
        }
        var iterator = startedStream.makeAsyncIterator()
        _ = await iterator.next()
        cancellation.cancel()

        let result = await task.value
        XCTAssertFalse(result.success)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.output, "Command cancelled")
    }

    func testHelperExecutablePathParsesPathField() {
        let output = """
        system/com.moe.controlpower.helper = {
            path = /Applications/ControlPower.app/Contents/Resources/ControlPowerHelper
        }
        """

        XCTAssertEqual(
            PowerDaemonClient.helperExecutablePath(fromLaunchctlOutput: output),
            "/Applications/ControlPower.app/Contents/Resources/ControlPowerHelper"
        )
    }

    func testHelperExecutablePathFallsBackToProgramField() {
        let output = """
        system/com.moe.controlpower.helper = {
            program = /Library/PrivilegedHelperTools/ControlPowerHelper
        }
        """

        XCTAssertEqual(
            PowerDaemonClient.helperExecutablePath(fromLaunchctlOutput: output),
            "/Library/PrivilegedHelperTools/ControlPowerHelper"
        )
    }

    func testHelperExecutablePathRejectsNonAbsolutePaths() {
        let output = """
        system/com.moe.controlpower.helper = {
            path = ControlPowerHelper
        }
        """

        XCTAssertNil(PowerDaemonClient.helperExecutablePath(fromLaunchctlOutput: output))
    }

    func testHelperLaunchDiagnosticsDetectsLaunchConstraintViolationFromEXCONFIG() {
        let output = """
        system/com.moe.controlpower.helper = {
            parent bundle identifier = com.moe.controlpower
            last exit code = 78: EX_CONFIG
            job state = spawn failed
        }
        """

        let diagnostics = PowerDaemonClient.helperLaunchDiagnostics(fromLaunchctlOutput: output)

        XCTAssertTrue(diagnostics.spawnFailed)
        XCTAssertTrue(diagnostics.launchConstraintViolation)
        XCTAssertEqual(diagnostics.lastExitCode, 78)
        XCTAssertEqual(diagnostics.lastExitDescription, "EX_CONFIG")
        XCTAssertEqual(diagnostics.parentBundleIdentifier, "com.moe.controlpower")
    }

    func testHelperLaunchDiagnosticsParsesGenericSpawnFailure() {
        let output = """
        system/com.moe.controlpower.helper = {
            last exit code = 1
            job state = spawn failed
        }
        """

        let diagnostics = PowerDaemonClient.helperLaunchDiagnostics(fromLaunchctlOutput: output)

        XCTAssertTrue(diagnostics.spawnFailed)
        XCTAssertFalse(diagnostics.launchConstraintViolation)
        XCTAssertEqual(diagnostics.lastExitCode, 1)
        XCTAssertNil(diagnostics.lastExitDescription)
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

    func testHelperConnectionAuthorizationPolicyRequiresSigningRequirement() {
        let policy = HelperConnectionAuthorizationPolicy(
            hasSigningRequirement: false,
            consoleUserIdentifier: 501
        )

        XCTAssertFalse(policy.allowsConnection(effectiveUserIdentifier: 501))
    }

    func testHelperConnectionAuthorizationPolicyAllowsNonRootWhenConsoleUserIdentifierUnavailable() {
        let policy = HelperConnectionAuthorizationPolicy(
            hasSigningRequirement: true,
            consoleUserIdentifier: nil
        )

        XCTAssertTrue(policy.allowsConnection(effectiveUserIdentifier: 501))
        XCTAssertFalse(policy.allowsConnection(effectiveUserIdentifier: 0))
    }

    func testHelperConnectionAuthorizationPolicyRequiresEffectiveUserMatch() {
        let policy = HelperConnectionAuthorizationPolicy(
            hasSigningRequirement: true,
            consoleUserIdentifier: 501
        )

        XCTAssertTrue(policy.allowsConnection(effectiveUserIdentifier: 501))
        XCTAssertFalse(policy.allowsConnection(effectiveUserIdentifier: 502))
    }

    func testOneTimeSessionTokenStoreConsumesTokenExactlyOnce() {
        let identifier = ObjectIdentifier(NSString(string: "connection"))
        var store = OneTimeSessionTokenStore()
        let token = store.issueToken(for: identifier)

        XCTAssertTrue(store.consumeToken(token, for: identifier))
        XCTAssertFalse(store.consumeToken(token, for: identifier))
    }

    func testOneTimeSessionTokenStoreClearsOutstandingToken() {
        let identifier = ObjectIdentifier(NSString(string: "connection"))
        var store = OneTimeSessionTokenStore()
        let token = store.issueToken(for: identifier)

        store.clearToken(for: identifier)

        XCTAssertFalse(store.consumeToken(token, for: identifier))
    }

    func testTrustedClientRequirementStringRequiresTeamIdentifier() {
        let requirement = CodeSigningRequirementBuilder.trustedClientRequirementString(
            bundleIdentifier: "com.moe.controlpower",
            teamIdentifier: nil
        )
        XCTAssertNil(requirement)
    }

    func testTrustedClientRequirementStringBuildsExpectedRule() {
        let requirement = CodeSigningRequirementBuilder.trustedClientRequirementString(
            bundleIdentifier: "com.moe.controlpower",
            teamIdentifier: "TEAM123"
        )

        XCTAssertEqual(
            requirement,
            "anchor apple generic and identifier \"com.moe.controlpower\" and certificate leaf[subject.OU] = \"TEAM123\""
        )
    }

    func testTrustedClientRequirementStringEscapesLiterals() {
        let requirement = CodeSigningRequirementBuilder.trustedClientRequirementString(
            bundleIdentifier: "com.moe.\"control\"power\\app",
            teamIdentifier: "TEAM\"\\\\123"
        )

        XCTAssertEqual(
            requirement,
            "anchor apple generic and identifier \"com.moe.\\\"control\\\"power\\\\app\" and certificate leaf[subject.OU] = \"TEAM\\\"\\\\\\\\123\""
        )
    }

    func testTrustedClientRequirementStringCompilesToSecRequirement() {
        let requirementString = CodeSigningRequirementBuilder.trustedClientRequirementString(
            bundleIdentifier: "com.moe.controlpower",
            teamIdentifier: "TEAM123"
        )
        XCTAssertNotNil(requirementString)
        XCTAssertNotNil(CodeSigningRequirementBuilder.requirement(from: requirementString ?? ""))
    }

    func testHelperExecutableRequirementStringBuildsExpectedRule() {
        let requirement = CodeSigningRequirementBuilder.helperExecutableRequirementString(teamIdentifier: "TEAM123")

        XCTAssertEqual(
            requirement,
            "anchor apple generic and identifier \"com.moe.controlpower.helper.bin\" and certificate leaf[subject.OU] = \"TEAM123\""
        )
    }

    func testHelperExecutableRequirementStringOmitsTeamIdentifierWhenUnavailable() {
        let requirement = CodeSigningRequirementBuilder.helperExecutableRequirementString(teamIdentifier: nil)

        XCTAssertEqual(
            requirement,
            "anchor apple generic and identifier \"com.moe.controlpower.helper.bin\""
        )
    }

    func testHelperStatusAllowsWritesOnlyWhenEnabled() {
        XCTAssertTrue(PowerDaemonClient.helperStatusAllowsWrites(.enabled))
    }

    func testHelperStatusAllowsWritesRejectsUnavailableStates() {
        XCTAssertFalse(PowerDaemonClient.helperStatusAllowsWrites(.requiresApproval))
        XCTAssertFalse(PowerDaemonClient.helperStatusAllowsWrites(.notRegistered))
        XCTAssertFalse(PowerDaemonClient.helperStatusAllowsWrites(.notFound))
    }

    func testHelperWriteReadinessErrorAllowsEnabledStatus() {
        let error = PowerDaemonClient.helperWriteReadinessError(status: .enabled, helperReachable: false)
        XCTAssertNil(error)
    }

    func testHelperWriteReadinessErrorAllowsReachableHelper() {
        let error = PowerDaemonClient.helperWriteReadinessError(status: .requiresApproval, helperReachable: true)
        XCTAssertNil(error)
    }

    func testHelperWriteReadinessErrorIncludesCurrentStatusWhenBlocked() {
        let error = PowerDaemonClient.helperWriteReadinessError(status: .requiresApproval, helperReachable: false)
        let message = error?.localizedDescription ?? ""
        XCTAssertTrue(message.contains("Current helper status: Requires Approval"))
    }

    func testIsIgnorableBootoutFailureAcceptsSuccessfulResult() {
        let result = TimedProcessResult(success: true, output: "", timedOut: false)
        XCTAssertTrue(PowerDaemonClient.isIgnorableBootoutFailure(result))
    }

    func testIsIgnorableBootoutFailureRejectsTimeout() {
        let result = TimedProcessResult(success: false, output: "Command timed out", timedOut: true)
        XCTAssertFalse(PowerDaemonClient.isIgnorableBootoutFailure(result))
    }

    func testIsIgnorableBootoutFailureAcceptsMissingServiceOutput() {
        let result = TimedProcessResult(
            success: false,
            output: "Boot-out failed: 3: No such process",
            timedOut: false
        )
        XCTAssertTrue(PowerDaemonClient.isIgnorableBootoutFailure(result))
    }

    func testIsIgnorableBootoutFailureRejectsOperationNotPermittedOutput() {
        let result = TimedProcessResult(
            success: false,
            output: "Boot-out failed: 1: Operation not permitted",
            timedOut: false
        )
        XCTAssertFalse(PowerDaemonClient.isIgnorableBootoutFailure(result))
    }

    @MainActor
    func testRefreshStatusSurfacesSecuritySensitiveFallbackReason() async {
        let client = FakePowerDaemonClient()
        client.helperEnabled = true
        client.fetchStatusResult = .success(
            PowerHelperStatus(
                snapshot: PMSetSnapshot(disableSleep: false, lidWake: true, summary: "local"),
                source: .localFallback,
                fallbackReason: "Helper signature validation failed"
            )
        )

        let viewModel = AppViewModel(client: client)
        await viewModel.refreshStatus()

        XCTAssertEqual(
            viewModel.lastError,
            "Using local fallback status: Helper signature validation failed"
        )
    }

    @MainActor
    func testRefreshStatusDoesNotSurfaceNonSecurityFallbackReason() async {
        let client = FakePowerDaemonClient()
        client.helperEnabled = true
        client.fetchStatusResult = .success(
            PowerHelperStatus(
                snapshot: PMSetSnapshot(disableSleep: false, lidWake: true, summary: "local"),
                source: .localFallback,
                fallbackReason: "Helper response timed out after 18 seconds"
            )
        )

        let viewModel = AppViewModel(client: client)
        await viewModel.refreshStatus()

        XCTAssertNil(viewModel.lastError)
    }

    func testRemainingTimeStringFormatsHoursMinutesAndSeconds() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let endDate = now.addingTimeInterval(3_661)

        let result = AppViewModel.remainingTimeString(until: endDate, now: now)

        XCTAssertEqual(result, "1h 01m 01s")
    }

    func testDurationLabelFormatsHourAndMinutePresets() {
        XCTAssertEqual(AppViewModel.durationLabel(for: 45), "45m")
        XCTAssertEqual(AppViewModel.durationLabel(for: 60), "1h")
        XCTAssertEqual(AppViewModel.durationLabel(for: 240), "4h")
    }

    func testIsIgnorableUnregisterFailureDescriptionRecognizesMissingService() {
        XCTAssertTrue(
            PowerDaemonClient.isIgnorableUnregisterFailureDescription(
                "Operation failed: Could not find service"
            )
        )
    }

    func testIsIgnorableUnregisterFailureDescriptionRejectsUnexpectedErrors() {
        XCTAssertFalse(
            PowerDaemonClient.isIgnorableUnregisterFailureDescription(
                "Operation failed: permission denied"
            )
        )
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

        XCTAssertEqual(viewModel.selectedDurationMinutes, 0)
        XCTAssertFalse(viewModel.isTimerActive)
        XCTAssertEqual(client.lastDisableSleepValue, false)
    }

    @MainActor
    func testRepairDaemonClearsHelperNeedsRepair() async {
        let client = FakePowerDaemonClient()
        client.daemonBroken = true
        client.fetchStatusResult = .success(
            PowerHelperStatus(
                snapshot: PMSetSnapshot(disableSleep: false, lidWake: true, summary: "repaired"),
                source: .helper
            )
        )

        let viewModel = AppViewModel(client: client)
        viewModel.helperNeedsRepair = true

        client.daemonBroken = false
        await viewModel.repairDaemon()

        XCTAssertFalse(viewModel.helperNeedsRepair)
        XCTAssertNil(viewModel.lastError)
        XCTAssertEqual(client.repairDaemonCallCount, 1)
    }

    @MainActor
    func testRepairDaemonRefreshesSnapshotAfterRepair() async {
        let client = FakePowerDaemonClient()
        client.fetchStatusResult = .success(
            PowerHelperStatus(
                snapshot: PMSetSnapshot(disableSleep: false, lidWake: false, summary: "after-repair"),
                source: .helper
            )
        )

        let viewModel = AppViewModel(client: client)
        viewModel.snapshot = PMSetSnapshot(disableSleep: nil, lidWake: nil, summary: "before-repair")

        await viewModel.repairDaemon()

        XCTAssertEqual(client.repairDaemonCallCount, 1)
        XCTAssertEqual(client.fetchStatusCallCount, 1)
        XCTAssertEqual(viewModel.snapshot.summary, "after-repair")
        XCTAssertEqual(viewModel.statusSource, .helper)
    }

    @MainActor
    func testRepairDaemonReappliesDesiredNoSleepAfterRecovery() async {
        let client = FakePowerDaemonClient()
        client.fetchStatusResult = .success(
            PowerHelperStatus(
                snapshot: PMSetSnapshot(disableSleep: true, lidWake: true, summary: "before-repair"),
                source: .helper
            )
        )

        let viewModel = AppViewModel(client: client, isTestEnvironment: true)
        viewModel.setDisableSleepEnabled(true)
        await client.waitForMutationCallCount(1)
        await client.waitForIdleMutations()
        client.fetchStatusResult = .success(
            PowerHelperStatus(
                snapshot: PMSetSnapshot(disableSleep: false, lidWake: true, summary: "after-repair"),
                source: .helper
            )
        )

        await viewModel.repairDaemon()
        await waitForCondition { client.lastDisableSleepValue == true }
        await client.waitForMutationCallCount(2)
        await client.waitForIdleMutations()

        XCTAssertEqual(client.repairDaemonCallCount, 1)
        XCTAssertEqual(client.setDisableSleepCallCount, 2)
        XCTAssertEqual(client.lastDisableSleepValue, true)
    }

    @MainActor
    func testRepairDaemonFailurePersistsErrorAfterRefresh() async {
        let client = FakePowerDaemonClient()
        client.repairDaemonResult = .failure(FakePowerDaemonClientError.repairFailed)
        client.daemonBroken = true
        client.fetchStatusResult = .success(
            PowerHelperStatus(
                snapshot: PMSetSnapshot(disableSleep: nil, lidWake: nil, summary: "fallback"),
                source: .localFallback
            )
        )

        let viewModel = AppViewModel(client: client)
        viewModel.helperNeedsRepair = true

        await viewModel.repairDaemon()

        XCTAssertEqual(client.repairDaemonCallCount, 1)
        XCTAssertEqual(client.fetchStatusCallCount, 1)
        XCTAssertEqual(viewModel.lastError, "Helper repair failed: repair failed")
        XCTAssertTrue(viewModel.helperNeedsRepair)
    }

    @MainActor
    func testRepairDaemonLaunchConstraintFailureShowsActionableMessage() async {
        let client = FakePowerDaemonClient()
        client.repairDaemonResult = .failure(
            NSError(
                domain: "ControlPower.Helper",
                code: 16,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Helper launch failed with a launch constraint violation (EX_CONFIG/code-signing). Reinstall /Applications/ControlPower.app and avoid running a Debug build with the same bundle identifier."
                ]
            )
        )
        client.daemonBroken = true
        client.fetchStatusResult = .success(
            PowerHelperStatus(
                snapshot: PMSetSnapshot(disableSleep: nil, lidWake: nil, summary: "fallback"),
                source: .localFallback
            )
        )

        let viewModel = AppViewModel(client: client)
        viewModel.helperNeedsRepair = true

        await viewModel.repairDaemon()

        XCTAssertEqual(client.repairDaemonCallCount, 1)
        XCTAssertEqual(client.fetchStatusCallCount, 1)
        XCTAssertEqual(
            viewModel.lastError,
            "Helper repair failed: macOS blocked the helper launch due to a signing/launch constraint issue. Reinstall /Applications/ControlPower.app and avoid running Debug and release builds at the same time."
        )
        XCTAssertTrue(viewModel.helperNeedsRepair)
    }

    @MainActor
    func testRequiresHelperApprovalOnlyWhenStatusIsRequiresApproval() async {
        let client = FakePowerDaemonClient()
        client.daemonStatus = .requiresApproval
        let viewModel = AppViewModel(client: client)

        XCTAssertTrue(viewModel.requiresHelperApproval)
        XCTAssertEqual(viewModel.helperStatusText, "Needs Approval")
        XCTAssertFalse(viewModel.isHelperEnabled)
    }

    @MainActor
    func testDisabledHelperDoesNotRequireApprovalBannerState() async {
        let client = FakePowerDaemonClient()
        client.daemonStatus = .disabled
        let viewModel = AppViewModel(client: client)

        XCTAssertFalse(viewModel.requiresHelperApproval)
        XCTAssertEqual(viewModel.helperStatusText, "Disabled")
        XCTAssertFalse(viewModel.isHelperEnabled)
    }

    @MainActor
    func testStartupAutoRepairsWhenDaemonBroken() async {
        let client = FakePowerDaemonClient()
        client.daemonBroken = true

        let viewModel = AppViewModel(client: client, isTestEnvironment: false)
        viewModel.startup()
        await client.waitForRepairCallCount(1)

        XCTAssertEqual(client.repairDaemonCallCount, 1)
    }

    @MainActor
    func testDesiredNoSleepDefaultsFalse() async {
        let client = FakePowerDaemonClient()
        let viewModel = AppViewModel(client: client, isTestEnvironment: true)

        XCTAssertFalse(viewModel.desiredNoSleep)
        await Task.yield()
    }

    @MainActor
    func testToggleOnSetsDesiredNoSleep() async {
        let client = FakePowerDaemonClient()
        let viewModel = AppViewModel(client: client, isTestEnvironment: true)

        viewModel.setDisableSleepEnabled(true)
        await client.waitForMutationCallCount(1)
        await client.waitForIdleMutations()

        XCTAssertTrue(viewModel.desiredNoSleep)
    }

    @MainActor
    func testToggleOffClearsDesiredNoSleep() async {
        let client = FakePowerDaemonClient()
        let viewModel = AppViewModel(client: client, isTestEnvironment: true)

        viewModel.setDisableSleepEnabled(true)
        await client.waitForMutationCallCount(1)
        await client.waitForIdleMutations()
        viewModel.setDisableSleepEnabled(false)
        await client.waitForMutationCallCount(2)
        await client.waitForIdleMutations()

        XCTAssertFalse(viewModel.desiredNoSleep)
    }

    @MainActor
    func testRestoreDefaultsClearsDesiredNoSleep() async {
        let client = FakePowerDaemonClient()
        let viewModel = AppViewModel(client: client, isTestEnvironment: true)

        viewModel.setDisableSleepEnabled(true)
        await client.waitForMutationCallCount(1)
        await client.waitForIdleMutations()

        viewModel.restoreDefaults()
        await client.waitForMutationCallCount(2)
        await client.waitForIdleMutations()

        XCTAssertFalse(viewModel.desiredNoSleep)
    }

    @MainActor
    func testWakeReappliesWhenDesiredAndActualDisagree() async {
        let client = FakePowerDaemonClient()
        client.fetchStatusResult = .success(
            PowerHelperStatus(
                snapshot: PMSetSnapshot(disableSleep: false, lidWake: true, summary: "wake-off"),
                source: .helper
            )
        )

        let viewModel = AppViewModel(client: client, isTestEnvironment: true)
        viewModel.isLowBatteryProtectionEnabled = false
        viewModel.setDisableSleepEnabled(true)
        await client.waitForMutationCallCount(1)
        await client.waitForIdleMutations()

        let mutationCountBeforeWake = client.setDisableSleepCallCount
        await viewModel.handleSystemWake()
        await client.waitForMutationCallCount(mutationCountBeforeWake + 1)
        await client.waitForIdleMutations()

        XCTAssertEqual(client.setDisableSleepCallCount, mutationCountBeforeWake + 1)
        XCTAssertEqual(client.lastDisableSleepValue, true)
    }

    @MainActor
    func testWakeSkipsWhenDesiredFalse() async {
        let client = FakePowerDaemonClient()
        let viewModel = AppViewModel(client: client, isTestEnvironment: true)

        await viewModel.handleSystemWake()

        XCTAssertEqual(client.fetchStatusCallCount, 0)
        XCTAssertEqual(client.setDisableSleepCallCount, 0)
    }

    @MainActor
    func testWakeSkipsWhenActualMatchesDesired() async {
        let client = FakePowerDaemonClient()
        client.fetchStatusResult = .success(
            PowerHelperStatus(
                snapshot: PMSetSnapshot(disableSleep: true, lidWake: true, summary: "wake-on"),
                source: .helper
            )
        )

        let viewModel = AppViewModel(client: client, isTestEnvironment: true)
        viewModel.snapshot = PMSetSnapshot(disableSleep: true, lidWake: true, summary: "already-on")
        viewModel.setDisableSleepEnabled(true)

        let setCountBeforeWake = client.setDisableSleepCallCount
        let fetchCountBeforeWake = client.fetchStatusCallCount
        await viewModel.handleSystemWake()

        XCTAssertEqual(client.setDisableSleepCallCount, setCountBeforeWake)
        XCTAssertEqual(client.fetchStatusCallCount, fetchCountBeforeWake + 1)
    }

    @MainActor
    func testWakeReappliesWhenSnapshotUnknownAfterRefreshFailure() async {
        let client = FakePowerDaemonClient()
        let viewModel = AppViewModel(client: client, isTestEnvironment: true)
        viewModel.isLowBatteryProtectionEnabled = false
        viewModel.setDisableSleepEnabled(true)
        await client.waitForMutationCallCount(1)
        await client.waitForIdleMutations()

        client.fetchStatusResult = .failure(
            NSError(domain: "Test", code: 77, userInfo: [NSLocalizedDescriptionKey: "fetch failed"])
        )
        viewModel.snapshot = PMSetSnapshot(disableSleep: nil, lidWake: true, summary: "unknown")

        let mutationCountBeforeWake = client.setDisableSleepCallCount
        await viewModel.handleSystemWake()
        await client.waitForMutationCallCount(mutationCountBeforeWake + 1)
        await client.waitForIdleMutations()

        XCTAssertEqual(client.setDisableSleepCallCount, mutationCountBeforeWake + 1)
        XCTAssertEqual(client.lastDisableSleepValue, true)
    }

    @MainActor
    private func waitForCondition(
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let interval: UInt64 = 20_000_000
        var elapsed: UInt64 = 0
        while elapsed <= timeoutNanoseconds {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: interval)
            elapsed += interval
        }
        XCTFail(
            "Timed out waiting for condition after \(Double(timeoutNanoseconds) / 1_000_000_000) seconds",
            file: file,
            line: line
        )
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
        var repairDaemonResult: Result<Void, Error> = .success(())
        var helperStatus: HelperDaemonStatus = .enabled
        var setHelperEnabledShouldFail = false
        var holdFetchStatus = false
        var restoreDefaultsResult: Result<Void, Error> = .success(())
        var setDisableSleepResult: Result<Void, Error> = .success(())
        var daemonBroken = false
        var registerDaemonCallCount = 0
        var fetchStatusCallCount = 0
        var setHelperEnabledCallCount = 0
        var setDisableSleepCallCount = 0
        var restoreDefaultsCallCount = 0
        var repairDaemonCallCount = 0
        var maxConcurrentMutationCalls = 0
        var lastDisableSleepValue: Bool?
        var activeMutationCalls = 0
        var fetchStatusCountWait: (expected: Int, continuation: CheckedContinuation<Void, Never>)?
        var setHelperEnabledCountWait: (expected: Int, continuation: CheckedContinuation<Void, Never>)?
        var mutationCountWait: (expected: Int, continuation: CheckedContinuation<Void, Never>)?
        var repairCountWait: (expected: Int, continuation: CheckedContinuation<Void, Never>)?
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

    var repairDaemonResult: Result<Void, Error> {
        get { state.withLock { $0.repairDaemonResult } }
        set { state.withLock { $0.repairDaemonResult = newValue } }
    }

    var helperEnabled: Bool {
        get { state.withLock { $0.helperStatus == .enabled } }
        set {
            state.withLock { state in
                state.helperStatus = newValue ? .enabled : .disabled
            }
        }
    }

    var daemonStatus: HelperDaemonStatus {
        get { state.withLock { $0.helperStatus } }
        set { state.withLock { $0.helperStatus = newValue } }
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

    var setDisableSleepResult: Result<Void, Error> {
        get { state.withLock { $0.setDisableSleepResult } }
        set { state.withLock { $0.setDisableSleepResult = newValue } }
    }

    var fetchStatusCallCount: Int { state.withLock { $0.fetchStatusCallCount } }
    var setHelperEnabledCallCount: Int { state.withLock { $0.setHelperEnabledCallCount } }
    var registerDaemonCallCount: Int { state.withLock { $0.registerDaemonCallCount } }
    var setDisableSleepCallCount: Int { state.withLock { $0.setDisableSleepCallCount } }
    var restoreDefaultsCallCount: Int { state.withLock { $0.restoreDefaultsCallCount } }
    var repairDaemonCallCount: Int { state.withLock { $0.repairDaemonCallCount } }
    var maxConcurrentMutationCalls: Int { state.withLock { $0.maxConcurrentMutationCalls } }
    var lastDisableSleepValue: Bool? { state.withLock { $0.lastDisableSleepValue } }

    var daemonBroken: Bool {
        get { state.withLock { $0.daemonBroken } }
        set { state.withLock { $0.daemonBroken = newValue } }
    }

    func registerDaemonIfNeeded() async throws {
        let result = state.withLock { state in
            state.registerDaemonCallCount += 1
            return state.registerDaemonResult
        }
        try result.get()
    }

    func isHelperEnabled() -> Bool {
        helperStatus() == .enabled
    }

    func helperStatus() -> HelperDaemonStatus {
        state.withLock { $0.helperStatus }
    }

    func setHelperEnabled(_ enabled: Bool) async throws {
        let (shouldFail, waitContinuation) = state.withLock { state -> (Bool, CheckedContinuation<Void, Never>?) in
            state.setHelperEnabledCallCount += 1
            let waitContinuation: CheckedContinuation<Void, Never>?
            if let wait = state.setHelperEnabledCountWait, state.setHelperEnabledCallCount >= wait.expected {
                state.setHelperEnabledCountWait = nil
                waitContinuation = wait.continuation
            } else {
                waitContinuation = nil
            }
            return (state.setHelperEnabledShouldFail, waitContinuation)
        }
        waitContinuation?.resume()

        if shouldFail {
            throw FakePowerDaemonClientError.approvalMissing
        }
        state.withLock { state in
            state.helperStatus = enabled ? .enabled : .disabled
        }
    }

    func isDaemonBroken() async -> Bool {
        state.withLock { $0.daemonBroken }
    }

    func repairDaemon() async throws {
        let (waitContinuation, result) = state.withLock { state -> (CheckedContinuation<Void, Never>?, Result<Void, Error>) in
            state.repairDaemonCallCount += 1
            let waitContinuation: CheckedContinuation<Void, Never>?
            if let wait = state.repairCountWait, state.repairDaemonCallCount >= wait.expected {
                state.repairCountWait = nil
                waitContinuation = wait.continuation
            } else {
                waitContinuation = nil
            }
            return (waitContinuation, state.repairDaemonResult)
        }
        waitContinuation?.resume()
        try result.get()
    }

    @MainActor
    func waitForRepairCallCount(_ expected: Int) async {
        if state.withLock({ $0.repairDaemonCallCount >= expected }) {
            return
        }
        await withCheckedContinuation { continuation in
            let shouldResumeNow = state.withLock { state in
                if state.repairDaemonCallCount >= expected {
                    return true
                }
                state.repairCountWait = (expected, continuation)
                return false
            }
            if shouldResumeNow {
                continuation.resume()
            }
        }
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
    func waitForSetHelperEnabledCallCount(_ expected: Int) async {
        if state.withLock({ $0.setHelperEnabledCallCount >= expected }) {
            return
        }
        await withCheckedContinuation { continuation in
            let shouldResumeNow = state.withLock { state in
                if state.setHelperEnabledCallCount >= expected {
                    return true
                }
                state.setHelperEnabledCountWait = (expected, continuation)
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

    func displaySleepNow() async throws {
        await withMutationTracking()
    }

    func setDisableSleep(_ enabled: Bool) async throws {
        let (waitContinuation, result) = state.withLock { state -> (CheckedContinuation<Void, Never>?, Result<Void, Error>) in
            state.lastDisableSleepValue = enabled
            state.setDisableSleepCallCount += 1
            if let wait = state.mutationCountWait, state.totalMutationCallCount >= wait.expected {
                state.mutationCountWait = nil
                return (wait.continuation, state.setDisableSleepResult)
            }
            return (nil, state.setDisableSleepResult)
        }
        waitContinuation?.resume()
        await withMutationTracking()
        try result.get()
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
    case repairFailed
    case setDisableSleepFailed

    var errorDescription: String? {
        switch self {
        case .approvalMissing:
            return "approval missing"
        case .repairFailed:
            return "repair failed"
        case .setDisableSleepFailed:
            return "set disable sleep failed"
        }
    }
}
