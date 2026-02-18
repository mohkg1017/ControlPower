import AppKit
import Foundation
import ServiceManagement

struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let message: String
}

struct TerminalCommand: Identifiable {
    let id: String
    let title: String
    let command: String
    let detail: String
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var snapshot = PMSetSnapshot(disableSleep: nil, lidWake: nil, summary: "No status yet")
    @Published var statusSource: PowerStatusSource = .localFallback
    @Published var logEntries: [LogEntry] = []
    @Published var daemonStatus: SMAppService.Status = .notRegistered
    @Published var isBusy = false
    @Published var lastError: String?
    @Published var timedKeepAwakeEndDate: Date?

    private let client: any PowerDaemonClientProtocol
    private let settingsStore: SettingsStore
    private var refreshTask: Task<Void, Never>?
    private var startupSnapshot: PMSetSnapshot?
    private var timedKeepAwakeTask: Task<Void, Never>?
    private var hasStarted = false
    private static let maxLogEntries = 300

    var helperReadyForCommands: Bool {
        daemonStatus == .enabled
    }

    var helperNeedsApproval: Bool {
        daemonStatus == .requiresApproval
    }

    var selectedPreset: PowerPreset {
        PowerPreset(rawValue: settingsStore.settings.selectedPresetRawValue) ?? .appleDefaults
    }

    var customTimedKeepAwakeMinutes: Int {
        settingsStore.settings.customTimedKeepAwakeMinutes
    }

    var terminalCommands: [TerminalCommand] {
        [
            TerminalCommand(
                id: "disable-on",
                title: "Disable Sleep",
                command: "sudo pmset -a disablesleep 1",
                detail: "Turns global sleep off."
            ),
            TerminalCommand(
                id: "disable-off",
                title: "Enable Sleep (Default)",
                command: "sudo pmset -a disablesleep 0",
                detail: "Restores normal global sleep behavior."
            ),
            TerminalCommand(
                id: "lidwake-off",
                title: "Disable Lid Wake",
                command: "sudo pmset -a lidwake 0",
                detail: "Prevents lid open from triggering wake."
            ),
            TerminalCommand(
                id: "lidwake-on",
                title: "Enable Lid Wake (Default)",
                command: "sudo pmset -a lidwake 1",
                detail: "Restores normal lid wake behavior."
            ),
            TerminalCommand(
                id: "status",
                title: "Check Current Status",
                command: "pmset -g",
                detail: "Prints the current power management configuration."
            )
        ]
    }

    init(
        settingsStore: SettingsStore,
        client: any PowerDaemonClientProtocol = PowerDaemonClient()
    ) {
        self.settingsStore = settingsStore
        self.client = client
    }

    func startup() {
        guard !hasStarted else { return }
        hasStarted = true
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            appendLog("Skipping startup side effects in test environment")
            return
        }
        daemonStatus = client.daemonStatus
        applyLaunchAtLoginPreference()
        if settingsStore.settings.autoRegisterDaemonOnLaunch {
            registerDaemonIfNeeded()
        }
        Task { await refreshStatus() }
        restartRefreshLoop()
    }

    func restartRefreshLoop() {
        refreshTask?.cancel()
        let interval = max(60, settingsStore.settings.autoRefreshIntervalSeconds)
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.shouldAutoRefresh else { continue }
                await self.refreshStatus()
            }
        }
    }

    func applySettings() {
        applyLaunchAtLoginPreference()
        restartRefreshLoop()
    }

    func refreshStatus() async {
        guard !isBusy else { return }
        await perform("Refresh status") {
            let status = try await client.fetchStatus()
            guard !Task.isCancelled else { return }
            snapshot = status.snapshot
            statusSource = status.source
            daemonStatus = client.daemonStatus
            if startupSnapshot == nil {
                startupSnapshot = status.snapshot
            }
        }
    }

    func toggleDisableSleep() {
        clearTimedKeepAwake(shouldLog: false)
        let target = !(snapshot.disableSleep ?? false)
        Task {
            await perform("Set disablesleep to \(target ? "1" : "0")") {
                try await client.setDisableSleep(target)
                let status = try await client.fetchStatus()
                guard !Task.isCancelled else { return }
                snapshot = status.snapshot
                statusSource = status.source
            }
        }
    }

    func toggleLidWake() {
        clearTimedKeepAwake(shouldLog: false)
        let target = !(snapshot.lidWake ?? true)
        Task {
            await perform("Set lidwake to \(target ? "1" : "0")") {
                try await client.setLidWake(target)
                let status = try await client.fetchStatus()
                guard !Task.isCancelled else { return }
                snapshot = status.snapshot
                statusSource = status.source
            }
        }
    }

    func applyPreset(_ preset: PowerPreset) {
        clearTimedKeepAwake(shouldLog: false)
        setSelectedPreset(preset)
        Task {
            await perform("Apply preset: \(preset.title)") {
                try await client.applyPreset(preset)
                let status = try await client.fetchStatus()
                guard !Task.isCancelled else { return }
                snapshot = status.snapshot
                statusSource = status.source
            }
        }
    }

    func applySelectedPreset() {
        applyPreset(selectedPreset)
    }

    func setSelectedPreset(_ preset: PowerPreset) {
        settingsStore.update { $0.selectedPresetRawValue = preset.rawValue }
    }

    func restoreDefaults() {
        clearTimedKeepAwake(shouldLog: false)
        Task {
            await perform("Restore defaults") {
                try await client.restoreDefaults()
                let status = try await client.fetchStatus()
                guard !Task.isCancelled else { return }
                snapshot = status.snapshot
                statusSource = status.source
            }
        }
    }

    func startTimedKeepAwake(minutes: Int) {
        guard minutes > 0 else { return }
        clearTimedKeepAwake(shouldLog: false)
        Task {
            await perform("Enable keep awake for \(minutes) minutes") {
                try await client.setDisableSleep(true)
                let status = try await client.fetchStatus()
                guard !Task.isCancelled else { return }
                snapshot = status.snapshot
                statusSource = status.source
                scheduleTimedKeepAwakeRestore(minutes: minutes)
            }
        }
    }

    func startCustomTimedKeepAwake() {
        startTimedKeepAwake(minutes: customTimedKeepAwakeMinutes)
    }

    func setCustomTimedKeepAwakeMinutes(_ value: Int) {
        settingsStore.update { $0.customTimedKeepAwakeMinutes = min(max(value, 5), 720) }
    }

    func cancelTimedKeepAwake() {
        clearTimedKeepAwake(shouldLog: true)
    }

    func registerDaemonIfNeeded() {
        do {
            let before = client.daemonStatus
            try client.registerDaemon()
            daemonStatus = client.daemonStatus
            if before != daemonStatus {
                appendLog("Helper status changed to \(daemonStatusText())")
            } else {
                appendLog("Helper status unchanged: \(daemonStatusText())")
            }
        } catch {
            daemonStatus = client.daemonStatus
            lastError = error.localizedDescription
            appendLog("Daemon registration failed: \(error.localizedDescription)")
        }
    }

    func unregisterDaemon() {
        do {
            let before = client.daemonStatus
            try client.unregisterDaemon()
            daemonStatus = client.daemonStatus
            if before != daemonStatus {
                appendLog("Helper status changed to \(daemonStatusText())")
            } else {
                appendLog("Helper status unchanged: \(daemonStatusText())")
            }
        } catch {
            lastError = error.localizedDescription
            appendLog("Daemon unregister failed: \(error.localizedDescription)")
        }
    }

    func openLoginItemsSettings() {
        client.openLoginItemsSettings()
    }

    func daemonStatusText() -> String {
        switch daemonStatus {
        case .enabled:
            "Enabled"
        case .requiresApproval:
            "Requires Approval"
        case .notRegistered:
            "Not Registered"
        case .notFound:
            "Not Found"
        @unknown default:
            "Unknown"
        }
    }

    func statusSourceText() -> String {
        switch statusSource {
        case .helper:
            "Privileged Helper"
        case .localFallback:
            "Local Read-Only"
        }
    }

    func requestQuit() {
        guard settingsStore.settings.promptOnQuitIfChanged,
              stateChangedSinceStartup()
        else {
            settingsStore.flush()
            NSApp.terminate(nil)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Keep power changes?"
        alert.informativeText = "Your current pmset state differs from when ControlPower started."
        alert.addButton(withTitle: "Keep and Quit")
        alert.addButton(withTitle: "Restore Defaults and Quit")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            settingsStore.flush()
            NSApp.terminate(nil)
        case .alertSecondButtonReturn:
            Task {
                await perform("Restore defaults before quit") {
                    try await client.restoreDefaults()
                }
                settingsStore.flush()
                NSApp.terminate(nil)
            }
        default:
            return
        }
    }

    func copyTerminalCommand(_ item: TerminalCommand) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(item.command, forType: .string) {
            appendLog("Copied command: \(item.command)")
            return
        }
        lastError = "Failed to copy command to clipboard"
        appendLog("Failed to copy command: \(item.command)")
    }

    private func applyLaunchAtLoginPreference() {
        do {
            try client.setLaunchAtLogin(enabled: settingsStore.settings.launchAtLogin)
        } catch {
            lastError = error.localizedDescription
            appendLog("Launch at login update failed: \(error.localizedDescription)")
        }
    }

    private func appendLog(_ message: String) {
        logEntries.insert(LogEntry(date: Date(), message: message), at: 0)
        if logEntries.count > Self.maxLogEntries {
            logEntries.removeSubrange(Self.maxLogEntries...)
        }
    }

    private func scheduleTimedKeepAwakeRestore(minutes: Int) {
        timedKeepAwakeTask?.cancel()
        let endDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        timedKeepAwakeEndDate = endDate
        timedKeepAwakeTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0, endDate.timeIntervalSinceNow) * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.restoreDefaultsAfterTimedKeepAwake()
        }
    }

    private func restoreDefaultsAfterTimedKeepAwake() async {
        await perform("Timed keep awake ended; restoring defaults") {
            try await client.restoreDefaults()
            let status = try await client.fetchStatus()
            guard !Task.isCancelled else { return }
            snapshot = status.snapshot
            statusSource = status.source
        }
        timedKeepAwakeTask = nil
        timedKeepAwakeEndDate = nil
    }

    private func clearTimedKeepAwake(shouldLog: Bool) {
        let hadTimer = timedKeepAwakeEndDate != nil
        timedKeepAwakeTask?.cancel()
        timedKeepAwakeTask = nil
        timedKeepAwakeEndDate = nil
        if shouldLog, hadTimer {
            appendLog("Cancelled timed keep awake")
        }
    }

    private func stateChangedSinceStartup() -> Bool {
        guard let startupSnapshot else { return false }
        return startupSnapshot.disableSleep != snapshot.disableSleep || startupSnapshot.lidWake != snapshot.lidWake
    }

    private var shouldAutoRefresh: Bool {
        if NSApp.isActive {
            return true
        }
        return NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized }
    }

    private func perform(_ label: String, operation: () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await operation()
            lastError = nil
            appendLog(label)
            daemonStatus = client.daemonStatus
        } catch {
            lastError = error.localizedDescription
            appendLog("\(label) failed: \(error.localizedDescription)")
            daemonStatus = client.daemonStatus
        }
    }
}
