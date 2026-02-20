import Foundation
import ServiceManagement
import Synchronization

public enum PowerStatusSource: Sendable, Equatable {
    case helper
    case localFallback
}

public struct PowerHelperStatus: Sendable {
    public var snapshot: PMSetSnapshot
    public var source: PowerStatusSource
    public var fallbackReason: String?

    public init(snapshot: PMSetSnapshot, source: PowerStatusSource, fallbackReason: String? = nil) {
        self.snapshot = snapshot
        self.source = source
        self.fallbackReason = fallbackReason
    }
}

public protocol PowerDaemonClientProtocol: Sendable {
    func registerDaemonIfNeeded() throws
    func fetchStatus() async throws -> PowerHelperStatus
    func setDisableSleep(_ enabled: Bool) async throws
    func restoreDefaults() async throws
    func displaySleepNow() async throws
    func isHelperEnabled() -> Bool
    func setHelperEnabled(_ enabled: Bool) throws
    func isDaemonBroken() async -> Bool
    func repairDaemon() async throws
}

private struct LocalPMSetSnapshotCacheState {
    var snapshot: PMSetSnapshot?
    var fetchedAt: Date?
}

private struct XPCConnectionCancellationState<T: Sendable> {
    var gate: XPCReplyGate<T>?
}

private final class XPCConnectionCancellationBox<T: Sendable>: Sendable {
    private let state = Mutex(XPCConnectionCancellationState<T>(gate: nil))

    func install(_ gate: XPCReplyGate<T>) {
        state.withLock { $0.gate = gate }
    }

    func clear() {
        state.withLock { $0.gate = nil }
    }

    func cancel() {
        let gate = state.withLock { state -> XPCReplyGate<T>? in
            let gate = state.gate
            state.gate = nil
            return gate
        }
        gate?.finish(.failure(CancellationError()))
    }
}

public struct PowerDaemonClient: PowerDaemonClientProtocol {
    nonisolated private static let pmsetURL = URL(fileURLWithPath: "/usr/bin/pmset")
    nonisolated private static let launchctlURL = URL(fileURLWithPath: "/bin/launchctl")
    nonisolated private static let xpcTimeoutSeconds: TimeInterval = 18
    nonisolated private static let xpcProbeTimeoutSeconds: TimeInterval = 5
    nonisolated private static let localPMSetTimeoutSeconds: TimeInterval = 8
    nonisolated private static let registrationProbeTimeoutSeconds: TimeInterval = 3
    nonisolated private static let localSnapshotCacheTTLSeconds: TimeInterval = 1.5
    nonisolated private static let pmsetValidationError = SystemExecutableValidator.validateExecutable(at: pmsetURL)
    nonisolated private static let localSnapshotCache = Mutex(LocalPMSetSnapshotCacheState(snapshot: nil, fetchedAt: nil))

    public init() {}

    private var daemonService: SMAppService {
        SMAppService.daemon(plistName: PowerHelperConstants.daemonPlistName)
    }

    nonisolated static func helperStatusAllowsWrites(_ status: SMAppService.Status) -> Bool {
        status == .enabled
    }

    public func registerDaemonIfNeeded() throws {
        let service = daemonService
        switch service.status {
        case .notRegistered, .notFound:
            try service.register()
        case .enabled:
            return
        case .requiresApproval:
            return
        @unknown default:
            return
        }
    }

    public func isHelperEnabled() -> Bool {
        let service = daemonService
        return Self.helperStatusAllowsWrites(service.status)
    }

    public func setHelperEnabled(_ enabled: Bool) throws {
        let service = daemonService
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    }

    public func isDaemonBroken() async -> Bool {
        let service = daemonService
        guard service.status == .enabled else { return false }
        let task = Task.detached(priority: .utility) {
            let result = TimedProcessRunner(
                executableURL: Self.launchctlURL,
                timeoutSeconds: Self.registrationProbeTimeoutSeconds
            ).run(arguments: ["print", "system/\(PowerHelperConstants.daemonLabel)"])
            guard result.success else { return false }
            return result.output.contains("spawn failed") || result.output.contains("EX_CONFIG")
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func repairDaemon() async throws {
        let service = daemonService
        await bootoutDaemon()
        try? await service.unregister()
        try? await Task.sleep(for: .seconds(1))
        try service.register()
    }

    public func fetchStatus() async throws -> PowerHelperStatus {
        let service = daemonService
        if service.status != .enabled {
            let task = Task.detached(priority: .userInitiated) {
                try Self.fetchLocalPMSetSnapshot()
            }
            let snapshot = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            return PowerHelperStatus(
                snapshot: snapshot,
                source: .localFallback,
                fallbackReason: "Helper status is \(Self.daemonStatusDescription(service.status))"
            )
        }

        do {
            return try await Self.fetchStatusFromHelper()
        } catch {
            let task = Task.detached(priority: .userInitiated) {
                try Self.fetchLocalPMSetSnapshot()
            }
            let snapshot = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            return PowerHelperStatus(
                snapshot: snapshot,
                source: .localFallback,
                fallbackReason: error.controlPowerSanitizedDescription
            )
        }
    }

    public func setDisableSleep(_ enabled: Bool) async throws {
        try await performWrite {
            try await Self.simpleCall { proxy, done in
                proxy.setDisableSleep(enabled) { success, message in
                    done(success, message)
                }
            }
        }
    }

    public func restoreDefaults() async throws {
        try await performWrite {
            try await Self.simpleCall { proxy, done in
                proxy.restoreDefaults { success, message in
                    done(success, message)
                }
            }
        }
    }

    public func displaySleepNow() async throws {
        // `pmset displaysleepnow` is intentionally local so this action still works when the helper is not approved.
        if let pmsetValidationError = Self.pmsetValidationError {
            throw NSError(
                domain: "ControlPower.LocalPMSet",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: pmsetValidationError]
            )
        }
        let task = Task.detached(priority: .userInitiated) {
            TimedProcessRunner(executableURL: Self.pmsetURL, timeoutSeconds: Self.localPMSetTimeoutSeconds)
                .run(arguments: ["displaysleepnow"])
        }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard result.success else {
            throw NSError(
                domain: "ControlPower.LocalPMSet",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: result.timedOut ? "pmset displaysleepnow timed out" : (result.output.isEmpty ? "pmset displaysleepnow failed" : result.output)]
            )
        }
    }

    private func ensureHelperReadyForWrites() async throws {
        let status = daemonService.status
        if Self.helperStatusAllowsWrites(status) {
            return
        }

        let isReachable = (try? await Self.pingHelper(timeoutSeconds: Self.xpcProbeTimeoutSeconds)) == true
        if let helperReadinessError = Self.helperWriteReadinessError(status: status, helperReachable: isReachable) {
            throw helperReadinessError
        }
    }

    nonisolated private static func fetchStatusFromHelper() async throws -> PowerHelperStatus {
        try await withConnection { proxy, done in
            proxy.fetchStatus { success, disable, lid, summary, error in
                if !success {
                    done(nil, NSError(domain: "ControlPower.Helper", code: 1, userInfo: [NSLocalizedDescriptionKey: error]))
                    return
                }
                let snapshot = PMSetSnapshot(
                    disableSleep: disable == -1 ? nil : disable == 1,
                    lidWake: lid == -1 ? nil : lid == 1,
                    summary: summary
                )
                done(PowerHelperStatus(snapshot: snapshot, source: .helper), nil)
            }
        }
    }

    nonisolated private static func fetchLocalPMSetSnapshot() throws -> PMSetSnapshot {
        if let pmsetValidationError {
            throw NSError(
                domain: "ControlPower.LocalPMSet",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: pmsetValidationError]
            )
        }

        if let cachedSnapshot = localSnapshotCache.withLock({ cache -> PMSetSnapshot? in
            guard
                let snapshot = cache.snapshot,
                let fetchedAt = cache.fetchedAt,
                Date().timeIntervalSince(fetchedAt) <= localSnapshotCacheTTLSeconds
            else {
                return nil
            }
            return snapshot
        }) {
            return cachedSnapshot
        }

        let result = TimedProcessRunner(executableURL: pmsetURL, timeoutSeconds: localPMSetTimeoutSeconds)
            .run(arguments: ["-g"])
        guard result.success else {
            let output: String
            if result.timedOut {
                output = "pmset -g timed out after \(Int(localPMSetTimeoutSeconds)) seconds"
            } else if result.output.isEmpty {
                output = "pmset -g failed"
            } else {
                output = result.output
            }
            throw NSError(
                domain: "ControlPower.LocalPMSet",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: output]
            )
        }
        let snapshot = PMSetParser.parse(result.output)
        localSnapshotCache.withLock { cache in
            cache.snapshot = snapshot
            cache.fetchedAt = Date()
        }
        return snapshot
    }

    nonisolated static func helperWriteReadinessError(
        status: SMAppService.Status,
        helperReachable: Bool
    ) -> NSError? {
        guard !helperStatusAllowsWrites(status), !helperReachable else {
            return nil
        }

        return NSError(
            domain: "ControlPower.Helper",
            code: 8,
            userInfo: [NSLocalizedDescriptionKey: "Write actions need the ControlPower helper approved in System Settings > Login Items. Current helper status: \(daemonStatusDescription(status))."]
        )
    }

    private nonisolated static func daemonStatusDescription(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled:
            return "Enabled"
        case .requiresApproval:
            return "Requires Approval"
        case .notRegistered:
            return "Not Registered"
        case .notFound:
            return "Not Found"
        @unknown default:
            return "Unknown"
        }
    }

    private func performWrite(_ writeOperation: @escaping () async throws -> Void) async throws {
        try await ensureHelperReadyForWrites()
        try await writeOperation()
    }

    nonisolated private func bootoutDaemon() async {
        let task = Task.detached(priority: .utility) {
            TimedProcessRunner(
                executableURL: Self.launchctlURL,
                timeoutSeconds: Self.registrationProbeTimeoutSeconds
            ).run(arguments: ["bootout", "system/\(PowerHelperConstants.daemonLabel)"])
        }
        _ = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated private static func simpleCall(_ action: @escaping (PowerHelperXPCProtocol, @escaping (Bool, String) -> Void) -> Void) async throws {
        try await withConnection { proxy, done in
            action(proxy) { success, message in
                if success {
                    done((), nil)
                } else {
                    done(nil, NSError(domain: "ControlPower.Helper", code: 2, userInfo: [NSLocalizedDescriptionKey: message]))
                }
            }
        }
    }

    nonisolated private static func pingHelper(timeoutSeconds: TimeInterval) async throws -> Bool {
        try await withConnection(timeoutSeconds: timeoutSeconds) { proxy, done in
            proxy.ping { value in
                done(value == "pong", nil)
            }
        }
    }

    nonisolated private static func withConnection<T: Sendable>(
        timeoutSeconds: TimeInterval = Self.xpcTimeoutSeconds,
        _ block: @escaping (PowerHelperXPCProtocol, @escaping (T?, Error?) -> Void) -> Void
    ) async throws -> T {
        let cancellationBox = XPCConnectionCancellationBox<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let connection = NSXPCConnection(machServiceName: PowerHelperConstants.machServiceName, options: .privileged)
                connection.remoteObjectInterface = NSXPCInterface(with: PowerHelperXPCProtocol.self)
                let gate = XPCReplyGate(continuation: continuation)
                let finish: (Result<T, Error>) -> Void = { result in
                    connection.invalidate()
                    cancellationBox.clear()
                    gate.finish(result)
                }
                cancellationBox.install(gate)

                connection.interruptionHandler = {
                    finish(.failure(NSError(
                        domain: "ControlPower.Helper",
                        code: 5,
                        userInfo: [NSLocalizedDescriptionKey: "Helper connection interrupted"]
                    )))
                }
                connection.invalidationHandler = {
                    finish(.failure(NSError(
                        domain: "ControlPower.Helper",
                        code: 6,
                        userInfo: [NSLocalizedDescriptionKey: "Helper connection invalidated"]
                    )))
                }

                let timeoutTask = Task {
                    try? await Task.sleep(for: .seconds(timeoutSeconds))
                    guard !Task.isCancelled else { return }
                    cancellationBox.clear()
                    gate.finish(.failure(NSError(
                        domain: "ControlPower.Helper",
                        code: 7,
                        userInfo: [NSLocalizedDescriptionKey: "Helper response timed out after \(Int(timeoutSeconds.rounded())) seconds"]
                    )))
                }
                gate.installTimeoutTask(timeoutTask)

                connection.resume()

                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    finish(.failure(error))
                }) as? PowerHelperXPCProtocol else {
                    finish(.failure(NSError(
                        domain: "ControlPower.Helper",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Remote proxy unavailable"]
                    )))
                    return
                }

                block(proxy) { value, error in
                    if let error {
                        finish(.failure(error))
                        return
                    }
                    guard let value else {
                        finish(.failure(NSError(
                            domain: "ControlPower.Helper",
                            code: 4,
                            userInfo: [NSLocalizedDescriptionKey: "Missing response payload"]
                        )))
                        return
                    }
                    finish(.success(value))
                }
            }
        } onCancel: {
            cancellationBox.cancel()
        }
    }
}

private struct XPCReplyGateState<T: Sendable> {
    var continuation: CheckedContinuation<T, Error>?
    var timeoutTask: Task<Void, Never>?
}

final class XPCReplyGate<T: Sendable>: Sendable {
    private let state: Mutex<XPCReplyGateState<T>>
    private let onFinish: (@Sendable () -> Void)?

    init(continuation: CheckedContinuation<T, Error>) {
        self.state = Mutex(XPCReplyGateState(continuation: continuation, timeoutTask: nil))
        self.onFinish = nil
    }

    init(continuation: CheckedContinuation<T, Error>, onFinish: @escaping @Sendable () -> Void) {
        self.state = Mutex(XPCReplyGateState(continuation: continuation, timeoutTask: nil))
        self.onFinish = onFinish
    }

    func installTimeoutTask(_ task: Task<Void, Never>) {
        let previousTask = state.withLock { state in
            let previousTask = state.timeoutTask
            state.timeoutTask = task
            return previousTask
        }
        previousTask?.cancel()
    }

    func finish(_ result: Result<T, Error>) {
        let continuationAndTimeout: (CheckedContinuation<T, Error>, Task<Void, Never>?)? = state.withLock { state in
            guard let continuation = state.continuation else {
                return nil
            }
            state.continuation = nil
            let timeoutTask = state.timeoutTask
            state.timeoutTask = nil
            return (continuation, timeoutTask)
        }

        guard let (continuation, timeoutTask) = continuationAndTimeout else {
            return
        }

        timeoutTask?.cancel()
        onFinish?()

        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
