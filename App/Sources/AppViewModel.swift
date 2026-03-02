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
        private let helperStatusOperation: @Sendable () -> HelperDaemonStatus
        private let setHelperEnabledOperation: @Sendable (Bool) async throws -> Void
        private let isDaemonBrokenOperation: @Sendable () async -> Bool
        private let repairDaemonOperation: @Sendable () async throws -> Void

        init<Client: PowerDaemonClientProtocol>(_ client: Client) {
            registerDaemonIfNeededOperation = { try await client.registerDaemonIfNeeded() }
            fetchStatusOperation = { try await client.fetchStatus() }
            setDisableSleepOperation = { enabled in try await client.setDisableSleep(enabled) }
            restoreDefaultsOperation = { try await client.restoreDefaults() }
            displaySleepNowOperation = { try await client.displaySleepNow() }
            helperStatusOperation = { client.helperStatus() }
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

        func helperStatus() -> HelperDaemonStatus {
            helperStatusOperation()
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
    nonisolated private static let desiredNoSleepKey = "desiredNoSleep"
    nonisolated private static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    nonisolated private static let maxPendingMutations = 64
    nonisolated public static let appVersion: String = {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Version \(v) (Build \(b))"
    }()

    public var snapshot = PMSetSnapshot(disableSleep: nil, lidWake: nil, summary: "No status yet")
    public var statusSource: PowerStatusSource = .localFallback
    public var helperStatus: HelperDaemonStatus = .disabled
    public var isHelperEnabled = false
    public var isBusy = false
    public var lastError: String?
    public var helperNeedsRepair = false

    public var selectedDurationMinutes: Int = 60
    @ObservationIgnored
    private var timerTask: Task<Void, Never>?
    @ObservationIgnored
    private var startupTask: Task<Void, Never>?
    @ObservationIgnored
    private var batteryNotificationTask: Task<Void, Never>?
    @ObservationIgnored
    private var wakeNotificationTask: Task<Void, Never>?
    private var timerEndDate: Date?

    public var batteryLevel: Int = 100
    private var isOnBatteryPower = false
    public var isLowBatteryProtectionEnabled: Bool = true {
        didSet {
            if shouldPersistLowBatteryProtection {
                UserDefaults.standard.set(isLowBatteryProtectionEnabled, forKey: Self.lowBatteryProtectionKey)
            }
            checkBatterySafety()
        }
    }
    @ObservationIgnored public private(set) var desiredNoSleep: Bool = false
    @ObservationIgnored private var batterySourceRunLoopSource: CFRunLoopSource?
    @ObservationIgnored private var batteryMonitorContextPointer: UnsafeMutableRawPointer?
    @ObservationIgnored private var wakeObserver: AnyObject?

    @ObservationIgnored
    private let client: ClientOperations
    @ObservationIgnored
    private let mutationScheduler: MutationScheduler
    @ObservationIgnored
    private let isTestEnvironment: Bool
    @ObservationIgnored
    private let shouldPersistLowBatteryProtection: Bool
    @ObservationIgnored
    private let shouldPersistDesiredNoSleep: Bool
    @ObservationIgnored
    private var lowBatteryAutoDisableQueued = false
    private var pendingHelperEnabledRequest: Bool?
    private var pendingDisableSleepRequest: Bool?
    @ObservationIgnored
    private var wakeReapplyInFlight = false
    @ObservationIgnored
    private var hasStarted = false
    @ObservationIgnored
    private var timerRequestIdentifier = 0

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
        self.isOnBatteryPower = isTestEnvironment
        self.shouldPersistLowBatteryProtection = !isTestEnvironment
        self.shouldPersistDesiredNoSleep = !isTestEnvironment && !Self.isRunningTests
        self.isLowBatteryProtectionEnabled = isTestEnvironment
            ? true
            : (UserDefaults.standard.object(forKey: Self.lowBatteryProtectionKey) as? Bool ?? true)
        self.desiredNoSleep = shouldPersistDesiredNoSleep
            ? (UserDefaults.standard.object(forKey: Self.desiredNoSleepKey) as? Bool ?? false)
            : false
        self.helperStatus = clientOperations.helperStatus()
        self.isHelperEnabled = helperStatus == .enabled
        if !isTestEnvironment {
            setupBatteryMonitoring()
            setupWakeMonitoring()
        }
    }

    @MainActor
    deinit {
        timerTask?.cancel()
        startupTask?.cancel()
        batteryNotificationTask?.cancel()
        wakeNotificationTask?.cancel()
        mutationScheduler.cancelAll()
        tearDownBatteryMonitoring()
        tearDownWakeMonitoring()
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

    public var isReapplyingNoSleep: Bool {
        desiredNoSleep && snapshot.disableSleep != true && !helperNeedsRepair
    }

    public var statusIconName: String {
        if isReapplyingNoSleep {
            return "arrow.trianglehead.2.clockwise"
        }
        switch powerMode {
        case .noSleep: return "moon.zzz.fill"
        case .normal: return "checkmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    public var statusTitle: String {
        if isReapplyingNoSleep {
            return "Re-applying No Sleep…"
        }
        switch powerMode {
        case .noSleep: return "No Sleep Active"
        case .normal: return "Normal Mode"
        case .unknown: return "Status Unknown"
        }
    }

    public var statusDescription: String {
        if isReapplyingNoSleep {
            return "Trying to restore your no-sleep setting."
        }
        switch powerMode {
        case .noSleep: return "Your Mac will stay awake."
        case .normal: return "Mac follows system sleep settings."
        case .unknown: return "Refresh to check power status."
        }
    }

    public var statusTint: PowerStatusTint {
        if isReapplyingNoSleep {
            return .unknown
        }
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

        startupTask = Task { @MainActor [weak self] in
            await self?.runStartupSequence()
        }
    }

    @MainActor
    private func runStartupSequence() async {
        defer { startupTask = nil }
        var didRegisterFail = false

        do {
            try await client.registerDaemonIfNeeded()
        } catch {
            didRegisterFail = true
            lastError = error.controlPowerSanitizedDescription
        }
        guard !Task.isCancelled else { return }

        refreshHelperStatusFromClient()
        helperNeedsRepair = await client.isDaemonBroken()
        guard !Task.isCancelled else { return }

        await refreshStatus()
        guard !Task.isCancelled else { return }

        let shouldRepairAfterFallback = didRegisterFail && statusSource == .localFallback
        if helperNeedsRepair || shouldRepairAfterFallback {
            if shouldRepairAfterFallback {
                helperNeedsRepair = true
            }
            await repairDaemon()
            guard !Task.isCancelled else { return }
        }

        reapplyDesiredNoSleepIfNeeded()
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

        refreshHelperStatusFromClient()
        do {
            let status = try await client.fetchStatus()
            guard !Task.isCancelled else { return }
            if snapshot != status.snapshot { snapshot = status.snapshot }
            statusSource = status.source
            if isHelperEnabled {
                helperNeedsRepair = await client.isDaemonBroken()
            } else {
                helperNeedsRepair = false
            }
            if status.source == .localFallback,
               isHelperEnabled,
               let reason = status.fallbackReason,
               shouldSurfaceFallbackReason(reason) {
                lastError = "Using local fallback status: \(reason)"
            } else {
                lastError = nil
            }
            checkBatterySafety()
        } catch {
            let daemonBroken = await client.isDaemonBroken()
            helperNeedsRepair = isHelperEnabled && daemonBroken
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
        refreshHelperStatusFromClient()
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

        enqueueMutation(key: "setHelperEnabled") { [weak self] in
            guard let self else { return }
            self.isBusy = true
            defer { self.isBusy = false }
            defer {
                if self.pendingHelperEnabledRequest == target {
                    self.pendingHelperEnabledRequest = nil
                }
            }

            self.refreshHelperStatusFromClient()
            let currentHelperState = self.isHelperEnabled
            if currentHelperState == target {
                self.helperNeedsRepair = currentHelperState ? await self.client.isDaemonBroken() : false
                self.lastError = nil
                return
            }

            do {
                try await self.client.setHelperEnabled(target)
                self.refreshHelperStatusFromClient()
            } catch {
                self.lastError = "Failed to \(target ? "enable" : "disable") helper: \(error.controlPowerSanitizedDescription)"
                self.refreshHelperStatusFromClient()
                self.helperNeedsRepair = self.isHelperEnabled ? await self.client.isDaemonBroken() : false
                return
            }

            do {
                try await self.refreshSnapshotFromClient()
                self.refreshHelperStatusFromClient()
                self.helperNeedsRepair = self.isHelperEnabled ? await self.client.isDaemonBroken() : false
                self.lastError = nil
            } catch {
                self.lastError = "Helper was \(target ? "enabled" : "disabled"), but status refresh failed: \(error.controlPowerSanitizedDescription)"
                self.refreshHelperStatusFromClient()
                self.helperNeedsRepair = self.isHelperEnabled ? await self.client.isDaemonBroken() : false
            }
        }
    }

    public func toggleDisableSleep() {
        setDisableSleepEnabled(!disableSleepDisplayValue)
    }

    public func setDisableSleepEnabled(_ enabled: Bool) {
        setDisableSleep(enabled)
    }

    public func startTimer(minutes: Int) {
        cancelTimer()
        let normalizedMinutes = max(0, minutes)
        selectedDurationMinutes = normalizedMinutes

        if normalizedMinutes == 0 {
            setDisableSleep(false, forceWrite: true)
            return
        }

        let requestIdentifier = timerRequestIdentifier
        if snapshot.disableSleep == true {
            updateDesiredNoSleep(true)
            activateTimer(minutes: normalizedMinutes, requestIdentifier: requestIdentifier)
            return
        }

        enqueueOperation("Start timer", key: "setDisableSleep") { viewModel in
            guard viewModel.timerRequestIdentifier == requestIdentifier else { return }
            viewModel.updateDesiredNoSleep(true)
            try await viewModel.client.setDisableSleep(true)
            try? await viewModel.refreshSnapshotFromClient()
            guard viewModel.timerRequestIdentifier == requestIdentifier else { return }
            viewModel.activateTimer(minutes: normalizedMinutes, requestIdentifier: requestIdentifier)
        }
    }

    public func cancelTimer() {
        timerRequestIdentifier &+= 1
        timerTask?.cancel()
        timerTask = nil
        timerEndDate = nil
    }

    public func sleepDisplay() {
        enqueueOperation("Sleep display") { viewModel in
            try await viewModel.client.displaySleepNow()
        }
    }

    public func restoreDefaults() {
        cancelTimer()
        updateDesiredNoSleep(false)
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

    public var requiresHelperApproval: Bool {
        helperStatus == .requiresApproval
    }

    public var helperStatusText: String {
        switch helperStatus {
        case .enabled:
            return "Active"
        case .requiresApproval:
            return "Needs Approval"
        case .disabled:
            return "Disabled"
        }
    }

    public var disableSleepDisplayValue: Bool {
        if let pendingDisableSleepRequest {
            return pendingDisableSleepRequest
        }
        if isReapplyingNoSleep {
            return true
        }
        return snapshot.disableSleep ?? false
    }

    public var helperEnabledDisplayValue: Bool {
        pendingHelperEnabledRequest ?? isHelperEnabled
    }

    public var isTimerActive: Bool {
        timerEndDate != nil
    }

    public var activeTimerEndDate: Date? {
        timerEndDate
    }

    public var remainingTimeString: String? {
        guard let timerEndDate else { return nil }
        return Self.remainingTimeString(until: timerEndDate)
    }

    nonisolated public static func remainingTimeString(until endDate: Date, now: Date = Date()) -> String? {
        let totalSeconds = max(0, Int(ceil(endDate.timeIntervalSince(now))))
        guard totalSeconds > 0 else { return nil }
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
            Task { @MainActor [weak viewModel = monitorContext.viewModel] in
                viewModel?.scheduleBatteryUpdate()
            }
        }, contextPointer)?.takeRetainedValue() else {
            Unmanaged<BatteryMonitorContext>.fromOpaque(contextPointer).release()
            return
        }

        batteryMonitorContextPointer = contextPointer
        batterySourceRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private func tearDownBatteryMonitoring() {
        if let source = batterySourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            batterySourceRunLoopSource = nil
        }
        if let contextPointer = batteryMonitorContextPointer {
            Unmanaged<BatteryMonitorContext>.fromOpaque(contextPointer).release()
            batteryMonitorContextPointer = nil
        }
    }

    private func setupWakeMonitoring() {
        tearDownWakeMonitoring()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.scheduleWakeHandling()
            }
        } as AnyObject
    }

    private func tearDownWakeMonitoring() {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
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
        var batteryPowerCapacity: Int?
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
                batteryPowerCapacity = capacity
                break
            }
        }

        if let batteryPowerCapacity {
            isOnBatteryPower = true
            batteryLevel = batteryPowerCapacity
            checkBatterySafety()
            return
        }

        isOnBatteryPower = false
        if let firstCapacity {
            batteryLevel = firstCapacity
            checkBatterySafety()
        }
    }

    private func checkBatterySafety() {
        guard isLowBatteryProtectionEnabled && isOnBatteryPower && batteryLevel <= 20 && snapshot.disableSleep == true else {
            lowBatteryAutoDisableQueued = false
            return
        }
        guard !lowBatteryAutoDisableQueued else { return }
        lowBatteryAutoDisableQueued = true
        lastError = "Low battery (≤20%). Disabling 'No Sleep' to save power."
        setDisableSleepEnabled(false)
    }

    private func finishTimerIfNeeded() {
        timerTask = nil
        timerEndDate = nil
        setDisableSleep(false, forceWrite: true)
    }

    private func activateTimer(minutes: Int, requestIdentifier: Int) {
        guard timerRequestIdentifier == requestIdentifier else { return }

        timerEndDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        timerTask = Task { @MainActor [weak self] in
            while let self, let timerEndDate = self.timerEndDate {
                guard self.timerRequestIdentifier == requestIdentifier else { return }
                guard timerEndDate.timeIntervalSinceNow > 0 else { break }

                let appIsActive = NSApp.isActive
                let sleepInterval: Duration = appIsActive ? .seconds(5) : .seconds(15)
                let sleepTolerance: Duration = appIsActive ? .seconds(1) : .seconds(3)
                do {
                    try await Task.sleep(for: sleepInterval, tolerance: sleepTolerance)
                } catch {
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            guard self.timerRequestIdentifier == requestIdentifier else { return }
            self.finishTimerIfNeeded()
        }
    }

    func handleSystemWake() async {
        guard desiredNoSleep else { return }
        guard !wakeReapplyInFlight else { return }
        wakeReapplyInFlight = true
        defer { wakeReapplyInFlight = false }

        await refreshStatus(force: true)
        reapplyDesiredNoSleepIfNeeded()
    }

    private func setDisableSleep(_ enabled: Bool, forceWrite: Bool = false) {
        let target = enabled
        pendingDisableSleepRequest = target
        updateDesiredNoSleep(enabled)
        if !forceWrite, let currentValue = snapshot.disableSleep, currentValue == target {
            if pendingDisableSleepRequest == target {
                pendingDisableSleepRequest = nil
            }
            return
        }
        if !target {
            cancelTimer()
        }
        let shouldClearLowBatteryGuard = !target
        enqueueOperation("Set no-sleep mode to \(target ? "on" : "off")", key: "setDisableSleep") { viewModel in
            defer {
                if viewModel.pendingDisableSleepRequest == target {
                    viewModel.pendingDisableSleepRequest = nil
                }
                if shouldClearLowBatteryGuard {
                    viewModel.lowBatteryAutoDisableQueued = false
                }
            }
            try await viewModel.client.setDisableSleep(target)
            try await viewModel.refreshSnapshotFromClient()
        }
    }

    private func reapplyDesiredNoSleepIfNeeded() {
        guard desiredNoSleep else { return }
        guard !helperNeedsRepair else { return }
        guard snapshot.disableSleep != true else { return }
        setDisableSleep(true)
    }

    private func updateDesiredNoSleep(_ desired: Bool) {
        guard desiredNoSleep != desired else { return }
        desiredNoSleep = desired
        guard shouldPersistDesiredNoSleep else { return }
        UserDefaults.standard.set(desired, forKey: Self.desiredNoSleepKey)
    }

    public func copyRawOutputToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snapshot.summary, forType: .string)
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
        if snapshot != status.snapshot { snapshot = status.snapshot }
        statusSource = status.source
    }

    private func refreshHelperStatusFromClient() {
        helperStatus = client.helperStatus()
        isHelperEnabled = helperStatus == .enabled
    }

    private func scheduleBatteryUpdate() {
        guard batteryNotificationTask == nil else { return }
        batteryNotificationTask = Task { @MainActor [weak self] in
            defer { self?.batteryNotificationTask = nil }
            self?.updateBatteryLevelFromSystem()
        }
    }

    private func scheduleWakeHandling() {
        guard wakeNotificationTask == nil else { return }
        wakeNotificationTask = Task { @MainActor [weak self] in
            defer { self?.wakeNotificationTask = nil }
            await self?.handleSystemWake()
        }
    }

    private func shouldSurfaceFallbackReason(_ reason: String) -> Bool {
        let normalized = reason.lowercased()
        return normalized.contains("signature")
            || normalized.contains("launch constraint")
            || normalized.contains("unauthorized")
            || normalized.contains("token")
            || normalized.contains("connection")
    }

    private func enqueueOperation(
        _ label: String,
        key: String? = nil,
        operation: @escaping (AppViewModel) async throws -> Void
    ) {
        enqueueMutation(key: key) { [weak self] in
            guard let self else { return }
            self.isBusy = true
            defer { self.isBusy = false }
            do {
                try await operation(self)
                self.lastError = nil
            } catch {
                self.lastError = "\(label) failed: \(error.controlPowerSanitizedDescription)"
            }
        }
    }

    private func enqueueMutation(key: String? = nil, _ mutation: @escaping () async -> Void) {
        mutationScheduler.enqueue(key: key, mutation, onOverflow: { [weak self] in
            self?.lastError = "Too many pending actions. Please wait for current changes to finish."
        })
    }
}
