import Foundation
import ServiceManagement
import XCTest
@testable import ControlPower

final class ControlPowerTests: XCTestCase {
    func testAppSettingsDefaultsToApplePreset() {
        let settings = AppSettings()
        XCTAssertEqual(settings.selectedPresetRawValue, PowerPreset.appleDefaults.rawValue)
    }

    func testAppSettingsDefaultsToCustomTimedDuration() {
        let settings = AppSettings()
        XCTAssertEqual(settings.customTimedKeepAwakeMinutes, 45)
    }

    func testAppSettingsDecodeBackfillsMissingKeys() throws {
        let data = """
        {
          "launchAtLogin": false,
          "selectedPresetRawValue": 2
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertEqual(settings.selectedPresetRawValue, 2)
        XCTAssertEqual(settings.autoRefreshIntervalSeconds, 60)
        XCTAssertEqual(settings.customTimedKeepAwakeMinutes, 45)
    }

    func testAppSettingsDecodeClampsRangeValues() throws {
        let data = """
        {
          "autoRefreshIntervalSeconds": 1,
          "customTimedKeepAwakeMinutes": 1000
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(settings.autoRefreshIntervalSeconds, 60)
        XCTAssertEqual(settings.customTimedKeepAwakeMinutes, 720)
    }

    @MainActor
    func testSettingsStoreMigratesLegacyFileToVersionedEnvelope() throws {
        let url = makeTemporarySettingsURL(testName: #function)

        var legacy = AppSettings()
        legacy.launchAtLogin = false
        legacy.customTimedKeepAwakeMinutes = 120
        legacy.selectedPresetRawValue = PowerPreset.deskMode.rawValue
        try JSONEncoder().encode(legacy).write(to: url, options: .atomic)

        let store = SettingsStore(settingsURL: url)

        XCTAssertFalse(store.settings.launchAtLogin)
        XCTAssertEqual(store.settings.customTimedKeepAwakeMinutes, 120)
        XCTAssertEqual(store.settings.selectedPresetRawValue, PowerPreset.deskMode.rawValue)

        store.flush()

        let savedData = try Data(contentsOf: url)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: savedData) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertNotNil(object["settings"] as? [String: Any])
    }

    @MainActor
    func testSettingsStoreBacksUpCorruptFileAndResets() throws {
        let nowDate = Date(timeIntervalSince1970: 1_700_000_000)
        let url = makeTemporarySettingsURL(testName: #function)
        try Data("{ this is not valid json".utf8).write(to: url, options: .atomic)

        let store = SettingsStore(
            settingsURL: url,
            now: { nowDate }
        )

        XCTAssertNotNil(store.persistenceError)
        XCTAssertEqual(store.settings, AppSettings())

        let backupURL = url
            .deletingPathExtension()
            .appendingPathExtension("corrupt-\(Int(nowDate.timeIntervalSince1970)).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
    }

    @MainActor
    func testSettingsStoreRejectsUnsupportedVersionWithoutBackup() throws {
        let nowDate = Date(timeIntervalSince1970: 1_700_000_123)
        let url = makeTemporarySettingsURL(testName: #function)
        let raw = """
        {
          "version": 99,
          "settings": {
            "launchAtLogin": false,
            "autoRegisterDaemonOnLaunch": true,
            "autoRefreshIntervalSeconds": 60,
            "promptOnQuitIfChanged": true,
            "showThermalWarning": true,
            "customTimedKeepAwakeMinutes": 45,
            "selectedPresetRawValue": 3
          }
        }
        """
        try Data(raw.utf8).write(to: url, options: .atomic)

        let store = SettingsStore(
            settingsURL: url,
            now: { nowDate }
        )

        XCTAssertEqual(store.settings, AppSettings())
        XCTAssertEqual(store.persistenceError, "Unsupported settings file version (99).")

        let backupURL = url
            .deletingPathExtension()
            .appendingPathExtension("corrupt-\(Int(nowDate.timeIntervalSince1970)).json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))

        let savedData = try Data(contentsOf: url)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: savedData) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 99)
    }

    @MainActor
    func testViewModelRefreshUpdatesStateFromInjectedClient() async {
        let store = SettingsStore(settingsURL: makeTemporarySettingsURL(testName: #function))
        let client = FakePowerDaemonClient()
        client.daemonStatus = .enabled
        client.fetchStatusResult = .success(
            PowerHelperStatus(
                snapshot: PMSetSnapshot(disableSleep: true, lidWake: false, summary: "mock-summary"),
                source: .helper
            )
        )

        let viewModel = AppViewModel(settingsStore: store, client: client)
        await viewModel.refreshStatus()

        XCTAssertEqual(viewModel.snapshot.disableSleep, true)
        XCTAssertEqual(viewModel.snapshot.lidWake, false)
        XCTAssertEqual(viewModel.snapshot.summary, "mock-summary")
        XCTAssertEqual(viewModel.statusSource, .helper)
        XCTAssertEqual(client.fetchStatusCallCount, 1)
    }

    @MainActor
    func testViewModelRefreshSkipsConcurrentRequests() async {
        let store = SettingsStore(settingsURL: makeTemporarySettingsURL(testName: #function))
        let client = FakePowerDaemonClient()
        client.daemonStatus = .enabled
        client.holdFetchStatus = true

        let viewModel = AppViewModel(settingsStore: store, client: client)

        async let firstRefresh: Void = viewModel.refreshStatus()
        await client.waitForFetchStatusCallCount(1)
        await viewModel.refreshStatus()
        client.resumeHeldFetchStatus()
        await firstRefresh

        XCTAssertEqual(client.fetchStatusCallCount, 1)
    }

    @MainActor
    func testViewModelRefreshLogsFallbackReason() async {
        let store = SettingsStore(settingsURL: makeTemporarySettingsURL(testName: #function))
        let client = FakePowerDaemonClient()
        client.daemonStatus = .notRegistered
        client.fetchStatusResult = .success(
            PowerHelperStatus(
                snapshot: PMSetSnapshot(disableSleep: nil, lidWake: nil, summary: "fallback"),
                source: .localFallback,
                fallbackReason: "Helper status is Not Registered"
            )
        )

        let viewModel = AppViewModel(settingsStore: store, client: client)
        await viewModel.refreshStatus()

        XCTAssertTrue(viewModel.logEntries.contains { $0.message.contains("Using local fallback: Helper status is Not Registered") })
    }

    @MainActor
    func testViewModelMutationsRunSequentially() async {
        let store = SettingsStore(settingsURL: makeTemporarySettingsURL(testName: #function))
        let client = FakePowerDaemonClient()
        client.daemonStatus = .enabled

        let viewModel = AppViewModel(settingsStore: store, client: client)
        viewModel.toggleDisableSleep()
        viewModel.toggleLidWake()

        await client.waitForMutationCallCount(2)
        await client.waitForIdleMutations()

        XCTAssertEqual(client.setDisableSleepCallCount, 1)
        XCTAssertEqual(client.setLidWakeCallCount, 1)
        XCTAssertEqual(client.maxConcurrentMutationCalls, 1)
    }

    @MainActor
    func testRequestQuitRestoreFailureDoesNotTerminate() async {
        let store = SettingsStore(settingsURL: makeTemporarySettingsURL(testName: #function))
        let client = FakePowerDaemonClient()
        client.daemonStatus = .enabled
        client.fetchStatusResult = .success(
            PowerHelperStatus(
                snapshot: PMSetSnapshot(disableSleep: false, lidWake: true, summary: "initial"),
                source: .helper
            )
        )
        client.restoreDefaultsResult = .failure(NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "restore failed"]))

        var terminateCount = 0
        let viewModel = AppViewModel(
            settingsStore: store,
            client: client,
            presentQuitPrompt: { .restoreDefaultsAndQuit },
            terminateApp: { terminateCount += 1 }
        )

        await viewModel.refreshStatus()
        viewModel.snapshot = PMSetSnapshot(disableSleep: true, lidWake: false, summary: "changed")
        viewModel.requestQuit()
        await client.waitForMutationCallCount(1)
        await client.waitForIdleMutations()

        XCTAssertEqual(terminateCount, 0)
        XCTAssertEqual(client.restoreDefaultsCallCount, 1)
        XCTAssertEqual(viewModel.lastError, "restore failed")
    }

    @MainActor
    func testRequestQuitRestoreSuccessTerminates() async {
        let store = SettingsStore(settingsURL: makeTemporarySettingsURL(testName: #function))
        let client = FakePowerDaemonClient()
        client.daemonStatus = .enabled
        client.fetchStatusResult = .success(
            PowerHelperStatus(
                snapshot: PMSetSnapshot(disableSleep: false, lidWake: true, summary: "initial"),
                source: .helper
            )
        )

        var terminateCount = 0
        let viewModel = AppViewModel(
            settingsStore: store,
            client: client,
            presentQuitPrompt: { .restoreDefaultsAndQuit },
            terminateApp: { terminateCount += 1 }
        )

        await viewModel.refreshStatus()
        viewModel.snapshot = PMSetSnapshot(disableSleep: true, lidWake: false, summary: "changed")
        viewModel.requestQuit()
        await client.waitForMutationCallCount(1)
        await client.waitForIdleMutations()

        XCTAssertEqual(terminateCount, 1)
        XCTAssertEqual(client.restoreDefaultsCallCount, 1)
    }

    @MainActor
    func testRequestQuitKeepAndQuitSkipsRestore() async {
        let store = SettingsStore(settingsURL: makeTemporarySettingsURL(testName: #function))
        let client = FakePowerDaemonClient()
        client.daemonStatus = .enabled
        client.fetchStatusResult = .success(
            PowerHelperStatus(
                snapshot: PMSetSnapshot(disableSleep: false, lidWake: true, summary: "initial"),
                source: .helper
            )
        )

        var terminateCount = 0
        let viewModel = AppViewModel(
            settingsStore: store,
            client: client,
            presentQuitPrompt: { .keepAndQuit },
            terminateApp: { terminateCount += 1 }
        )

        await viewModel.refreshStatus()
        viewModel.snapshot = PMSetSnapshot(disableSleep: true, lidWake: false, summary: "changed")
        viewModel.requestQuit()

        XCTAssertEqual(terminateCount, 1)
        XCTAssertEqual(client.restoreDefaultsCallCount, 0)
    }

    @MainActor
    func testStartTimedKeepAwakeSchedulesRestoreWhenStatusRefreshFails() async {
        let store = SettingsStore(settingsURL: makeTemporarySettingsURL(testName: #function))
        let client = FakePowerDaemonClient()
        client.daemonStatus = .enabled
        client.fetchStatusResult = .failure(
            NSError(domain: "Test", code: 2, userInfo: [NSLocalizedDescriptionKey: "refresh failed"])
        )

        let viewModel = AppViewModel(settingsStore: store, client: client)
        viewModel.startTimedKeepAwake(minutes: 30)
        await client.waitForMutationCallCount(1)
        await client.waitForIdleMutations()

        XCTAssertEqual(client.setDisableSleepCallCount, 1)
        XCTAssertNotNil(viewModel.timedKeepAwakeEndDate)
        XCTAssertEqual(viewModel.lastError, "refresh failed")
    }

    @MainActor
    func testUnregisterDaemonFailureUpdatesDisplayedStatus() {
        let store = SettingsStore(settingsURL: makeTemporarySettingsURL(testName: #function))
        let client = FakePowerDaemonClient()
        client.daemonStatus = .enabled
        client.daemonStatusAfterUnregisterAttempt = .notRegistered
        client.unregisterDaemonError = NSError(domain: "Test", code: 3, userInfo: [NSLocalizedDescriptionKey: "unregister failed"])

        let viewModel = AppViewModel(settingsStore: store, client: client)
        viewModel.daemonStatus = .enabled
        viewModel.unregisterDaemon()

        XCTAssertEqual(viewModel.daemonStatus, .notRegistered)
        XCTAssertEqual(viewModel.lastError, "unregister failed")
    }

    func testPMSetParserReadsValues() {
        let text = """
        System-wide power settings:
         SleepDisabled\t\t1
        Currently in use:
         lidwake              0
        """
        let snapshot = PMSetParser.parse(text)
        XCTAssertEqual(snapshot.disableSleep, true)
        XCTAssertEqual(snapshot.lidWake, false)
    }

    func testPMSetParserHandlesMissingKeys() {
        let text = """
        System-wide power settings:
         standby              1
        """
        let snapshot = PMSetParser.parse(text)
        XCTAssertNil(snapshot.disableSleep)
        XCTAssertNil(snapshot.lidWake)
    }

    func testPMSetParserTrimsSummary() {
        let text = """

        System-wide power settings:
         SleepDisabled 0
         lidwake       1

        """
        let snapshot = PMSetParser.parse(text)
        XCTAssertEqual(snapshot.disableSleep, false)
        XCTAssertEqual(snapshot.lidWake, true)
        XCTAssertTrue(snapshot.summary.hasPrefix("System-wide power settings:"))
        XCTAssertFalse(snapshot.summary.hasSuffix("\n"))
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

    private func makeTemporarySettingsURL(testName: String) -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ControlPowerTests", isDirectory: true)
            .appendingPathComponent(testName.replacingOccurrences(of: " ", with: "_"), isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("settings.json")
    }
}

@MainActor
private final class FakePowerDaemonClient: PowerDaemonClientProtocol {
    var daemonStatus: SMAppService.Status = .notRegistered
    var fetchStatusResult: Result<PowerHelperStatus, Error> = .success(
        PowerHelperStatus(
            snapshot: PMSetSnapshot(disableSleep: nil, lidWake: nil, summary: "default"),
            source: .localFallback
        )
    )
    var holdFetchStatus = false
    var restoreDefaultsResult: Result<Void, Error> = .success(())
    var unregisterDaemonError: Error?
    var daemonStatusAfterUnregisterAttempt: SMAppService.Status?
    private(set) var fetchStatusCallCount = 0
    private(set) var setDisableSleepCallCount = 0
    private(set) var setLidWakeCallCount = 0
    private(set) var restoreDefaultsCallCount = 0
    private(set) var applyPresetCallCount = 0
    private(set) var maxConcurrentMutationCalls = 0
    private var activeMutationCalls = 0
    private var fetchStatusCountWait: (expected: Int, continuation: CheckedContinuation<Void, Never>)?
    private var mutationCountWait: (expected: Int, continuation: CheckedContinuation<Void, Never>)?
    private var idleMutationWait: CheckedContinuation<Void, Never>?
    private var heldFetchStatusContinuation: CheckedContinuation<Void, Never>?

    func registerDaemon() throws {}

    func unregisterDaemon() throws {
        if let daemonStatusAfterUnregisterAttempt {
            daemonStatus = daemonStatusAfterUnregisterAttempt
        }
        if let unregisterDaemonError {
            throw unregisterDaemonError
        }
    }

    func openLoginItemsSettings() {}

    func setLaunchAtLogin(enabled: Bool) throws {}

    func waitForFetchStatusCallCount(_ expected: Int) async {
        guard fetchStatusCallCount < expected else { return }
        await withCheckedContinuation { continuation in
            fetchStatusCountWait = (expected, continuation)
        }
    }

    func waitForMutationCallCount(_ expected: Int) async {
        guard totalMutationCallCount < expected else { return }
        await withCheckedContinuation { continuation in
            mutationCountWait = (expected, continuation)
        }
    }

    func waitForIdleMutations() async {
        guard activeMutationCalls > 0 else { return }
        await withCheckedContinuation { continuation in
            idleMutationWait = continuation
        }
    }

    func resumeHeldFetchStatus() {
        heldFetchStatusContinuation?.resume()
        heldFetchStatusContinuation = nil
    }

    func fetchStatus() async throws -> PowerHelperStatus {
        fetchStatusCallCount += 1
        resolveFetchStatusCountWaitIfNeeded()
        if holdFetchStatus {
            await withCheckedContinuation { continuation in
                heldFetchStatusContinuation = continuation
            }
        }
        return try fetchStatusResult.get()
    }

    func setDisableSleep(_ enabled: Bool) async throws {
        setDisableSleepCallCount += 1
        resolveMutationCountWaitIfNeeded()
        await withMutationTracking()
    }

    func setLidWake(_ enabled: Bool) async throws {
        setLidWakeCallCount += 1
        resolveMutationCountWaitIfNeeded()
        await withMutationTracking()
    }

    func restoreDefaults() async throws {
        restoreDefaultsCallCount += 1
        resolveMutationCountWaitIfNeeded()
        await withMutationTracking()
        try restoreDefaultsResult.get()
    }

    func applyPreset(_ preset: PowerPreset) async throws {
        applyPresetCallCount += 1
        resolveMutationCountWaitIfNeeded()
        await withMutationTracking()
    }

    private func withMutationTracking() async {
        activeMutationCalls += 1
        if activeMutationCalls > maxConcurrentMutationCalls {
            maxConcurrentMutationCalls = activeMutationCalls
        }
        await Task.yield()
        activeMutationCalls -= 1
        if activeMutationCalls == 0 {
            idleMutationWait?.resume()
            idleMutationWait = nil
        }
    }

    private var totalMutationCallCount: Int {
        setDisableSleepCallCount + setLidWakeCallCount + restoreDefaultsCallCount + applyPresetCallCount
    }

    private func resolveFetchStatusCountWaitIfNeeded() {
        guard let wait = fetchStatusCountWait, fetchStatusCallCount >= wait.expected else { return }
        fetchStatusCountWait = nil
        wait.continuation.resume()
    }

    private func resolveMutationCountWaitIfNeeded() {
        guard let wait = mutationCountWait, totalMutationCallCount >= wait.expected else { return }
        mutationCountWait = nil
        wait.continuation.resume()
    }
}
