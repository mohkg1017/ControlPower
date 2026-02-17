import AppKit
import Foundation
import ServiceManagement

struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let message: String
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var snapshot = PMSetSnapshot(disableSleep: nil, lidWake: nil, summary: "No status yet")
    @Published var logEntries: [LogEntry] = []
    @Published var daemonStatus: SMAppService.Status = .notRegistered
    @Published var isBusy = false
    @Published var lastError: String?

    private let client = PowerDaemonClient()
    private let settingsStore: SettingsStore
    private var refreshTask: Task<Void, Never>?
    private var startupSnapshot: PMSetSnapshot?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    func startup() {
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
        let interval = max(10, settingsStore.settings.autoRefreshIntervalSeconds)
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.refreshStatus()
            }
        }
    }

    func applySettings() {
        applyLaunchAtLoginPreference()
        restartRefreshLoop()
    }

    func refreshStatus() async {
        await perform("Refresh status") {
            let status = try await client.fetchStatus()
            snapshot = status.snapshot
            daemonStatus = client.daemonStatus
            if startupSnapshot == nil {
                startupSnapshot = status.snapshot
            }
        }
    }

    func toggleDisableSleep() {
        let target = !(snapshot.disableSleep ?? false)
        Task {
            await perform("Set disablesleep to \(target ? "1" : "0")") {
                try await client.setDisableSleep(target)
                let status = try await client.fetchStatus()
                snapshot = status.snapshot
            }
        }
    }

    func toggleLidWake() {
        let target = !(snapshot.lidWake ?? true)
        Task {
            await perform("Set lidwake to \(target ? "1" : "0")") {
                try await client.setLidWake(target)
                let status = try await client.fetchStatus()
                snapshot = status.snapshot
            }
        }
    }

    func applyPreset(_ preset: PowerPreset) {
        Task {
            await perform("Apply preset: \(preset.title)") {
                try await client.applyPreset(preset)
                let status = try await client.fetchStatus()
                snapshot = status.snapshot
            }
        }
    }

    func restoreDefaults() {
        Task {
            await perform("Restore defaults") {
                try await client.restoreDefaults()
                let status = try await client.fetchStatus()
                snapshot = status.snapshot
            }
        }
    }

    func registerDaemonIfNeeded() {
        do {
            if client.daemonStatus == .notRegistered || client.daemonStatus == .notFound {
                try client.registerDaemon()
                appendLog("Registered privileged helper daemon")
            }
            daemonStatus = client.daemonStatus
        } catch {
            daemonStatus = client.daemonStatus
            lastError = error.localizedDescription
            appendLog("Daemon registration failed: \(error.localizedDescription)")
        }
    }

    func unregisterDaemon() {
        do {
            try client.unregisterDaemon()
            daemonStatus = client.daemonStatus
            appendLog("Unregistered privileged helper daemon")
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

    func requestQuit() {
        guard settingsStore.settings.promptOnQuitIfChanged,
              stateChangedSinceStartup()
        else {
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
            NSApp.terminate(nil)
        case .alertSecondButtonReturn:
            Task {
                await perform("Restore defaults before quit") {
                    try await client.restoreDefaults()
                }
                NSApp.terminate(nil)
            }
        default:
            return
        }
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
    }

    private func stateChangedSinceStartup() -> Bool {
        guard let startupSnapshot else { return false }
        return startupSnapshot.disableSleep != snapshot.disableSleep || startupSnapshot.lidWake != snapshot.lidWake
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
