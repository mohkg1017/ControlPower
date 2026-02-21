import AppKit
import Foundation
import IOKit.ps
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
    private final class BatteryMonitorContext {
        weak var viewModel: AppViewModel?

        init(viewModel: AppViewModel) {
            self.viewModel = viewModel
        }
    }

    private struct ClientOperations: Sendable {
        private let registerDaemonIfNeededOperation: @Sendable () async throws -> Void
        private let fetchStatusOperation: @Sendable () async throws -> PowerHelperStatus
        private let setDisableSleepOperation: @Sendable (Bool) async throws -> Void
        private let restoreDefaultsOperation: @Sendable () async throws -> Void
        private let displaySleepNowOperation: @Sendable () async throws -> Void
        private let isHelperEnabledOperation: @Sendable () -> Bool
        private let setHelperEnabledOperation: @Sendable (Bool) async throws -> Void
        private let isDaemonBrokenOperation: @Sendable () async -> Bool
        private let repairDaemonOperation: @Sendable () async throws -> Void

        init<Client: PowerDaemonClientProtocol>(_ client: Client) {
            registerDaemonIfNeededOperation = { try await client.registerDaemonIfNeeded() }
            fetchStatusOperation = { try await client.fetchStatus() }
            setDisableSleepOperation = { enabled in try await client.setDisableSleep(enabled) }
            restoreDefaultsOperation = { try await client.restoreDefaults() }
            displaySleepNowOperation = { try await client.displaySleepNow() }
            isHelperEnabledOperation = { client.isHelperEnabled() }
            setHelperEnabledOperation = { enabled in try await client.setHelperEnabled(enabled) }
            isDaemonBrokenOperation = { await client.isDaemonBroken() }
            repairDaemonOperation = { try await client.repairDaemon() }
        }

        func registerDaemonIfNeeded() async throws {
            try await registerDaemonIfNeededOperation()
        }

        func fetchStatus() async throws -> PowerHelperStatus {
            try await fetchStatusOperation()
        }

        func setDisableSleep(_ enabled: Bool) async throws {
            try await setDisableSleepOperation(enabled)
        }

        func restoreDefaults() async throws {
            try await restoreDefaultsOperation()
        }

        func displaySleepNow() async throws {
            try await displaySleepNowOperation()
        }

        func isHelperEnabled() -> Bool {
            isHelperEnabledOperation()
        }

        func setHelperEnabled(_ enabled: Bool) async throws {
            try await setHelperEnabledOperation(enabled)
        }

        func isDaemonBroken() async -> Bool {
            await isDaemonBrokenOperation()
        }

        func repairDaemon() async throws {
            try await repairDaemonOperation()
        }
    }

    nonisolated private static let lowBatteryProtectionKey = "lowBatteryProtection"
    nonisolated private static let maxPendingMutations = 64

    public var snapshot = PMSetSnapshot(disableSleep: nil, lidWake: nil, summary: "No status yet")
    public var statusSource: PowerStatusSource = .localFallback
    public var isHelperEnabled = false
    public var isBusy = false
    public var lastError: String?
    public var helperNeedsRepair = false

    public var remainingSeconds: Int?
    public var selectedDurationMinutes: Int = 60
    private var timerTask: Task<Void, Never>?
    private var timerEndDate: Date?

    public var batteryLevel: Int = 100
    public var isLowBatteryProtectionEnabled: Bool = true {
        didSet {
            guard shouldPersistLowBatteryProtection else { return }
            UserDefaults.standard.set(isLowBatteryProtectionEnabled, forKey: Self.lowBatteryProtectionKey)
        }
    }
    private var batterySourceRunLoopSource: CFRunLoopSource?
    private var batteryMonitorContextPointer: UnsafeMutableRawPointer?

    private let client: ClientOperations
    private let mutationScheduler: MutationScheduler
    private let isTestEnvironment: Bool
    private let shouldPersistLowBatteryProtection: Bool
    private var lowBatteryAutoDisableQueued = false
    private var pendingHelperEnabledRequest: Bool?
    private var hasStarted = false

    @MainActor
    public convenience init(
        client: PowerDaemonClient = PowerDaemonClient(),
        isTestEnvironment: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    ) {
        self.init(clientOperations: ClientOperations(client), isTestEnvironment: isTestEnvironment)
    }

    @MainActor
    public convenience init<Client: PowerDaemonClientProtocol>(
        client: Client,
        isTestEnvironment: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    ) {
        self.init(clientOperations: ClientOperations(client), isTestEnvironment: isTestEnvironment)
    }

    @MainActor
    private init(clientOperations: ClientOperations, isTestEnvironment: Bool) {
        self.client = clientOperations
        self.mutationScheduler = MutationScheduler(maxPendingMutations: Self.maxPendingMutations)
        self.isTestEnvironment = isTestEnvironment
        self.shouldPersistLowBatteryProtection = !isTestEnvironment
        self.isLowBatteryProtectionEnabled = isTestEnvironment
            ? true
            : (UserDefaults.standard.object(forKey: Self.lowBatteryProtectionKey) as? Bool ?? true)
        self.isHelperEnabled = clientOperations.isHelperEnabled()
        if !isTestEnvironment {
            setupBatteryMonitoring()
        }
    }

    @MainActor
    deinit {
        timerTask?.cancel()
        tearDownBatteryMonitoring()
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

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.client.registerDaemonIfNeeded()
            } catch {
                self.lastError = error.controlPowerSanitizedDescription
            }

            self.isHelperEnabled = self.client.isHelperEnabled()
            self.helperNeedsRepair = await self.client.isDaemonBroken()
            await self.refreshStatus()
            if self.helperNeedsRepair {
                await self.repairDaemon()
            }
        }
    }

    public func refreshStatus(force: Bool = false) async {
        let shouldManageBusy = !isBusy
        if !force && !shouldManageBusy {
            return
        }
        if shouldManageBusy {
            isBusy = true
        }
        defer {
            if shouldManageBusy {
                isBusy = false
            }
        }

        isHelperEnabled = client.isHelperEnabled()
        do {
            let status = try await client.fetchStatus()
            guard !Task.isCancelled else { return }
            snapshot = status.snapshot
            statusSource = status.source
            lastError = nil
            helperNeedsRepair = status.source == .localFallback && isHelperEnabled
            checkBatterySafety()
        } catch {
            if await client.isDaemonBroken() {
                helperNeedsRepair = true
            }
            lastError = "Refresh status failed: \(error.controlPowerSanitizedDescription)"
        }
    }

    public func repairDaemon() async {
        isBusy = true
        var repairErrorMessage: String?
        do {
            try await client.repairDaemon()
            lastError = nil
        } catch {
            let message = helperRepairFailureMessage(for: error)
            repairErrorMessage = message
            lastError = message
        }
        isHelperEnabled = client.isHelperEnabled()
        isBusy = false
        await refreshStatus(force: true)
        if let repairErrorMessage {
            lastError = repairErrorMessage
        }
    }

    public func toggleHelper() {
        setHelperEnabled(!isHelperEnabled)
    }

    public func setHelperEnabled(_ enabled: Bool) {
        let target = enabled
        pendingHelperEnabledRequest = target

        enqueueMutation { [weak self] in
            guard let self else { return }
            self.isBusy = true
            defer { self.isBusy = false }
            defer {
                if self.pendingHelperEnabledRequest == target {
                    self.pendingHelperEnabledRequest = nil
                }
            }

            let currentHelperState = self.client.isHelperEnabled()
            if currentHelperState == target {
                self.isHelperEnabled = currentHelperState
                self.helperNeedsRepair = currentHelperState ? await self.client.isDaemonBroken() : false
                self.lastError = nil
                return
            }

            do {
                try await self.client.setHelperEnabled(target)
                self.isHelperEnabled = self.client.isHelperEnabled()
            } catch {
                self.lastError = "Failed to \(target ? "enable" : "disable") helper: \(error.controlPowerSanitizedDescription)"
                self.isHelperEnabled = self.client.isHelperEnabled()
                self.helperNeedsRepair = self.isHelperEnabled ? await self.client.isDaemonBroken() : false
                return
            }

            do {
                try await self.refreshSnapshotFromClient()
                self.helperNeedsRepair = self.statusSource == .localFallback && self.isHelperEnabled
                self.lastError = nil
            } catch {
                self.lastError = "Helper was \(target ? "enabled" : "disabled"), but status refresh failed: \(error.controlPowerSanitizedDescription)"
                self.isHelperEnabled = self.client.isHelperEnabled()
                self.helperNeedsRepair = self.isHelperEnabled ? await self.client.isDaemonBroken() : false
            }
        }
    }

    public func toggleDisableSleep() {
        setDisableSleepEnabled(!(snapshot.disableSleep ?? false))
    }

    public func setDisableSleepEnabled(_ enabled: Bool) {
        setDisableSleep(enabled)
    }

    public func startTimer(minutes: Int) {
        cancelTimer()
        let normalizedMinutes = max(0, minutes)
        selectedDurationMinutes = normalizedMinutes
        remainingSeconds = normalizedMinutes * 60
        timerEndDate = Date().addingTimeInterval(TimeInterval(normalizedMinutes * 60))

        // Ensure No Sleep is ON
        if snapshot.disableSleep != true {
            setDisableSleep(true)
        }

        timerTask = Task { @MainActor [weak self] in
            while let self, let timerEndDate = self.timerEndDate {
                let secondsRemaining = max(0, Int(ceil(timerEndDate.timeIntervalSinceNow)))
                self.remainingSeconds = secondsRemaining > 0 ? secondsRemaining : nil
                guard secondsRemaining > 0 else { break }

                let appIsActive = NSApp.isActive
                let sleepInterval: Duration = appIsActive ? .seconds(1) : .seconds(5)
                let sleepTolerance: Duration = appIsActive ? .milliseconds(250) : .seconds(1)
                do {
                    try await Task.sleep(for: sleepInterval, tolerance: sleepTolerance)
                } catch {
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.finishTimerIfNeeded()
        }
    }

    public func cancelTimer() {
        timerTask?.cancel()
        timerTask = nil
        timerEndDate = nil
        remainingSeconds = nil
    }

    public func sleepDisplay() {
        enqueueOperation("Sleep display") { viewModel in
            try await viewModel.client.displaySleepNow()
        }
    }

    public func copyStatusToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(snapshot.summary, forType: .string)
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

    public var remainingTimeString: String? {
        guard let totalSeconds = remainingSeconds else { return nil }
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%dh %02dm %02ds", hours, minutes, seconds)
        }
        return String(format: "%02dm %02ds", minutes, seconds)
    }

    nonisolated public static func durationLabel(for minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h" : "\(minutes)m"
    }

    // MARK: - Internal

    private func setupBatteryMonitoring() {
        tearDownBatteryMonitoring()

        updateBatteryLevelFromSystem()

        let contextPointer = Unmanaged.passRetained(BatteryMonitorContext(viewModel: self)).toOpaque()

        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitorContext = Unmanaged<BatteryMonitorContext>.fromOpaque(context).takeUnretainedValue()
            guard let viewModel = monitorContext.viewModel else { return }
            Task { @MainActor in
                viewModel.updateBatteryLevelFromSystem()
            }
        }, contextPointer)?.takeRetainedValue() else {
            Unmanaged<BatteryMonitorContext>.fromOpaque(contextPointer).release()
            return
        }

        batteryMonitorContextPointer = contextPointer
        batterySourceRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    private func tearDownBatteryMonitoring() {
        if let source = batterySourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            batterySourceRunLoopSource = nil
        }
        if let contextPointer = batteryMonitorContextPointer {
            Unmanaged<BatteryMonitorContext>.fromOpaque(contextPointer).release()
            batteryMonitorContextPointer = nil
        }
    }

    private func updateBatteryLevelFromSystem() {
        guard
            let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return
        }

        var firstCapacity: Int?
        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                let capacity = description[kIOPSCurrentCapacityKey as String] as? Int
            else {
                continue
            }

            if firstCapacity == nil {
                firstCapacity = capacity
            }

            if let state = description[kIOPSPowerSourceStateKey as String] as? String,
               state == kIOPSBatteryPowerValue {
                batteryLevel = capacity
                checkBatterySafety()
                return
            }
        }

        if let firstCapacity {
            batteryLevel = firstCapacity
            checkBatterySafety()
        }
    }

    private func checkBatterySafety() {
        guard isLowBatteryProtectionEnabled && batteryLevel <= 20 && snapshot.disableSleep == true else {
            lowBatteryAutoDisableQueued = false
            return
        }
        guard !lowBatteryAutoDisableQueued else { return }
        lowBatteryAutoDisableQueued = true
        lastError = "Low battery (≤20%). Disabling 'No Sleep' to save power."
        setDisableSleepEnabled(false)
    }

    private func finishTimerIfNeeded() {
        let shouldDisableNoSleep = snapshot.disableSleep == true
        timerEndDate = nil
        remainingSeconds = nil
        guard shouldDisableNoSleep else { return }
        setDisableSleepEnabled(false)
    }

    private func setDisableSleep(_ enabled: Bool) {
        if let currentValue = snapshot.disableSleep, currentValue == enabled {
            return
        }
        if !enabled {
            cancelTimer()
        }
        let shouldClearLowBatteryGuard = !enabled
        enqueueOperation("Set disablesleep to \(enabled ? "1" : "0")") { viewModel in
            defer {
                if shouldClearLowBatteryGuard {
                    viewModel.lowBatteryAutoDisableQueued = false
                }
            }
            try await viewModel.client.setDisableSleep(enabled)
            try await viewModel.refreshSnapshotFromClient()
        }
    }

    private func helperRepairFailureMessage(for error: Error) -> String {
        let sanitized = error.controlPowerSanitizedDescription
        let normalized = sanitized.lowercased()
        if normalized.contains("launch constraint violation")
            || normalized.contains("code-signing")
            || normalized.contains("code signature")
            || normalized.contains("ex_config") {
            return "Helper repair failed: macOS blocked the helper launch due to a signing/launch constraint issue. Reinstall /Applications/ControlPower.app and avoid running Debug and release builds at the same time."
        }
        return "Helper repair failed: \(sanitized)"
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
        mutationScheduler.enqueue(mutation) { [weak self] in
            self?.lastError = "Too many pending actions. Please wait for current changes to finish."
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
            lastError = "\(label) failed: \(error.controlPowerSanitizedDescription)"
            return false
        }
    }
}
