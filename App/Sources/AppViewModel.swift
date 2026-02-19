import Foundation
import Observation

public enum PowerMode {
    case noSleep
    case normal
    case unknown
}

public enum PowerStatusTint {
    case noSleep
    case normal
    case unknown
}

@MainActor
@Observable
public final class AppViewModel {
    public var snapshot = PMSetSnapshot(disableSleep: nil, lidWake: nil, summary: "No status yet")
    public var statusSource: PowerStatusSource = .localFallback
    public var isHelperEnabled = false
    public var isBusy = false
    public var lastError: String?

    public var remainingSeconds: Int?
    public var selectedDurationMinutes: Int = 60
    private var timerTask: Task<Void, Never>?

    public var batteryLevel: Int = 100
    public var isLowBatteryProtectionEnabled: Bool = true
    private var batteryMonitorTask: Task<Void, Never>?

    private let client: any PowerDaemonClientProtocol
    private let isTestEnvironment: Bool
    private var pendingMutations: [() async -> Void] = []
    private var isProcessingMutations = false
    private var hasStarted = false

    @MainActor
    public init(
        client: any PowerDaemonClientProtocol = PowerDaemonClient(),
        isTestEnvironment: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    ) {
        self.client = client
        self.isTestEnvironment = isTestEnvironment
        self.isHelperEnabled = client.isHelperEnabled()
        if !isTestEnvironment {
            setupBatteryMonitoring()
        }
    }

    @MainActor
    deinit {
        timerTask?.cancel()
        batteryMonitorTask?.cancel()
    }

    public var powerMode: PowerMode {
        guard let disableSleep = snapshot.disableSleep else {
            return .unknown
        }
        return disableSleep ? .noSleep : .normal
    }

    public var noSleepText: String {
        guard let disableSleep = snapshot.disableSleep else { return "Unknown" }
        return disableSleep ? "ON" : "OFF"
    }

    public var statusIconName: String {
        switch powerMode {
        case .noSleep: return "moon.zzz.fill"
        case .normal: return "checkmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    public var statusTitle: String {
        switch powerMode {
        case .noSleep: return "No Sleep Active"
        case .normal: return "Normal Mode"
        case .unknown: return "Status Unknown"
        }
    }

    public var statusDescription: String {
        switch powerMode {
        case .noSleep: return "Your Mac will stay awake."
        case .normal: return "Mac follows system sleep settings."
        case .unknown: return "Refresh to check power status."
        }
    }

    public var statusTint: PowerStatusTint {
        switch powerMode {
        case .noSleep: return .noSleep
        case .normal: return .normal
        case .unknown: return .unknown
        }
    }

    public func startup() {
        guard !hasStarted else { return }
        hasStarted = true

        guard !isTestEnvironment else {
            return
        }

        do {
            try client.registerDaemonIfNeeded()
        } catch {
            lastError = safeErrorMessage(error)
        }
        
        isHelperEnabled = client.isHelperEnabled()

        Task { [weak self] in
            await self?.refreshStatus()
        }
    }

    public func refreshStatus() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        isHelperEnabled = client.isHelperEnabled()
        do {
            let status = try await client.fetchStatus()
            guard !Task.isCancelled else { return }
            snapshot = status.snapshot
            statusSource = status.source
            lastError = nil
            checkBatterySafety()
        } catch {
            lastError = "Refresh status failed: \(safeErrorMessage(error))"
        }
    }

    public func toggleHelper() {
        let target = !isHelperEnabled
        do {
            try client.setHelperEnabled(target)
            isHelperEnabled = client.isHelperEnabled()
            lastError = nil
            
            Task { [weak self] in
                await self?.refreshStatus()
            }
        } catch {
            lastError = "Failed to \(target ? "enable" : "disable") helper: \(safeErrorMessage(error))"
            isHelperEnabled = client.isHelperEnabled()
        }
    }

    public func toggleDisableSleep() {
        setDisableSleep(!(snapshot.disableSleep ?? false))
    }

    public func startTimer(minutes: Int) {
        cancelTimer()
        let normalizedMinutes = max(0, minutes)
        selectedDurationMinutes = normalizedMinutes
        remainingSeconds = normalizedMinutes * 60

        // Ensure No Sleep is ON
        if snapshot.disableSleep != true {
            setDisableSleep(true)
        }

        timerTask = Task { @MainActor [weak self] in
            while let self, let seconds = self.remainingSeconds, seconds > 0 {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                if Task.isCancelled { return }
                self.remainingSeconds = seconds - 1
            }
            guard let self, !Task.isCancelled else { return }
            self.finishTimerIfNeeded()
        }
    }

    public func cancelTimer() {
        timerTask?.cancel()
        timerTask = nil
        remainingSeconds = nil
    }

    public func restoreDefaults() {
        cancelTimer()
        enqueueOperation("Restore defaults") { viewModel in
            try await viewModel.client.restoreDefaults()
            try await viewModel.refreshSnapshotFromClient()
        }
    }

    public var sourceText: String {
        switch statusSource {
        case .helper:
            return "Privileged helper"
        case .localFallback:
            return "Local pmset read"
        }
    }

    // MARK: - Internal

    private func setupBatteryMonitoring() {
        batteryMonitorTask?.cancel()
        batteryMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.updateBatteryLevel()
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
            }
        }
    }

    private func updateBatteryLevel() async {
        let output = await Task.detached(priority: .utility) {
            TimedProcessRunner(executableURL: URL(fileURLWithPath: "/usr/bin/pmset"), timeoutSeconds: 5)
                .run(arguments: ["-g", "batt"]).output
        }.value
        
        if let range = output.range(of: #"\d+%"#, options: .regularExpression) {
            let percentage = String(output[range]).replacingOccurrences(of: "%", with: "")
            if let level = Int(percentage) {
                batteryLevel = level
                checkBatterySafety()
            }
        }
    }

    private func checkBatterySafety() {
        if isLowBatteryProtectionEnabled && batteryLevel <= 20 && snapshot.disableSleep == true {
            lastError = "Low battery (≤20%). Disabling 'No Sleep' to save power."
            setDisableSleep(false)
        }
    }

    private func finishTimerIfNeeded() {
        let shouldDisableNoSleep = snapshot.disableSleep == true
        remainingSeconds = nil
        guard shouldDisableNoSleep else { return }
        setDisableSleep(false)
    }

    private func setDisableSleep(_ enabled: Bool) {
        if !enabled {
            cancelTimer()
        }
        enqueueOperation("Set disablesleep to \(enabled ? "1" : "0")") { viewModel in
            try await viewModel.client.setDisableSleep(enabled)
            try await viewModel.refreshSnapshotFromClient()
        }
    }

    private func refreshSnapshotFromClient() async throws {
        let status = try await client.fetchStatus()
        guard !Task.isCancelled else { return }
        snapshot = status.snapshot
        statusSource = status.source
    }

    private func enqueueOperation(_ label: String, operation: @escaping (AppViewModel) async throws -> Void) {
        enqueueMutation { [weak self] in
            guard let self else { return }
            _ = await self.perform(label) {
                try await operation(self)
            }
        }
    }

    private func enqueueMutation(_ mutation: @escaping () async -> Void) {
        pendingMutations.append(mutation)
        guard !isProcessingMutations else { return }
        isProcessingMutations = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.pendingMutations.isEmpty {
                let next = self.pendingMutations.removeFirst()
                await next()
            }
            self.isProcessingMutations = false
        }
    }

    @discardableResult
    private func perform(_ label: String, operation: () async throws -> Void) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            try await operation()
            lastError = nil
            return true
        } catch {
            lastError = "\(label) failed: \(safeErrorMessage(error))"
            return false
        }
    }

    private func safeErrorMessage(_ error: Error) -> String {
        let sanitized = error.localizedDescription
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else {
            return "Unknown error"
        }
        return String(sanitized.prefix(200))
    }
}
