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
        client.fetchDelayNanoseconds = 300_000_000

        let viewModel = AppViewModel(settingsStore: store, client: client)

        async let firstRefresh: Void = viewModel.refreshStatus()
        try? await Task.sleep(nanoseconds: 30_000_000)
        await viewModel.refreshStatus()
        await firstRefresh

        XCTAssertEqual(client.fetchStatusCallCount, 1)
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
    var fetchDelayNanoseconds: UInt64 = 0
    private(set) var fetchStatusCallCount = 0

    func registerDaemon() throws {}

    func unregisterDaemon() throws {}

    func openLoginItemsSettings() {}

    func setLaunchAtLogin(enabled: Bool) throws {}

    func fetchStatus() async throws -> PowerHelperStatus {
        fetchStatusCallCount += 1
        if fetchDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: fetchDelayNanoseconds)
        }
        return try fetchStatusResult.get()
    }

    func setDisableSleep(_ enabled: Bool) async throws {}

    func setLidWake(_ enabled: Bool) async throws {}

    func restoreDefaults() async throws {}

    func applyPreset(_ preset: PowerPreset) async throws {}
}
