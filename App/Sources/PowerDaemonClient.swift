import Foundation
import ServiceManagement

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
    func isHelperEnabled() -> Bool
    func setHelperEnabled(_ enabled: Bool) throws
}

public struct PowerDaemonClient: PowerDaemonClientProtocol {
    nonisolated private static let pmsetURL = URL(fileURLWithPath: "/usr/bin/pmset")
    nonisolated private static let xpcTimeoutSeconds: TimeInterval = 8
    nonisolated private static let pmsetValidationError = SystemExecutableValidator.validateExecutable(at: pmsetURL)

    public init() {}

    private var daemonService: SMAppService {
        SMAppService.daemon(plistName: PowerHelperConstants.daemonPlistName)
    }

    public func registerDaemonIfNeeded() throws {
        switch daemonService.status {
        case .notRegistered, .notFound:
            try daemonService.register()
        case .enabled, .requiresApproval:
            return
        @unknown default:
            return
        }
    }

    public func isHelperEnabled() -> Bool {
        return daemonService.status == .enabled || daemonService.status == .requiresApproval
    }

    public func setHelperEnabled(_ enabled: Bool) throws {
        if enabled {
            try daemonService.register()
        } else {
            try daemonService.unregister()
        }
    }

    public func fetchStatus() async throws -> PowerHelperStatus {
        if daemonService.status != .enabled {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                try Self.fetchLocalPMSetSnapshot()
            }.value
            return PowerHelperStatus(
                snapshot: snapshot,
                source: .localFallback,
                fallbackReason: "Helper status is \(daemonStatusDescription(daemonService.status))"
            )
        }

        do {
            return try await Self.fetchStatusFromHelper()
        } catch {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                try Self.fetchLocalPMSetSnapshot()
            }.value
            return PowerHelperStatus(
                snapshot: snapshot,
                source: .localFallback,
                fallbackReason: Self.sanitizedErrorMessage(error)
            )
        }
    }

    public func setDisableSleep(_ enabled: Bool) async throws {
        try ensureHelperReadyForWrites()
        try await Self.simpleCall { proxy, done in
            proxy.setDisableSleep(enabled) { success, message in
                done(success, message)
            }
        }
    }

    public func restoreDefaults() async throws {
        try ensureHelperReadyForWrites()
        try await Self.simpleCall { proxy, done in
            proxy.restoreDefaults { success, message in
                done(success, message)
            }
        }
    }

    private func ensureHelperReadyForWrites() throws {
        guard daemonService.status == .enabled else {
            throw NSError(
                domain: "ControlPower.Helper",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "Write actions need the ControlPower helper approved in System Settings > Login Items."]
            )
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

        let result = TimedProcessRunner(executableURL: pmsetURL, timeoutSeconds: xpcTimeoutSeconds)
            .run(arguments: ["-g"])
        guard result.success else {
            let output: String
            if result.timedOut {
                output = "pmset -g timed out after \(Int(xpcTimeoutSeconds)) seconds"
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
        return PMSetParser.parse(result.output)
    }

    private func daemonStatusDescription(_ status: SMAppService.Status) -> String {
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

    nonisolated private static func sanitizedErrorMessage(_ error: Error) -> String {
        let sanitized = error.localizedDescription
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else {
            return "Unknown error"
        }
        return String(sanitized.prefix(200))
    }

    nonisolated private static func withConnection<T: Sendable>(
        _ block: @escaping (PowerHelperXPCProtocol, @escaping (T?, Error?) -> Void) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: PowerHelperConstants.machServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: PowerHelperXPCProtocol.self)
            let retainedConnectionAddress = UInt(bitPattern: Unmanaged.passRetained(connection).toOpaque())
            let gate = XPCReplyGate(continuation: continuation) {
                guard let retainedConnection = UnsafeMutableRawPointer(bitPattern: retainedConnectionAddress) else {
                    return
                }
                Unmanaged<NSXPCConnection>.fromOpaque(retainedConnection).takeRetainedValue().invalidate()
            }

            connection.interruptionHandler = {
                Task {
                    await gate.finish(.failure(NSError(
                        domain: "ControlPower.Helper",
                        code: 5,
                        userInfo: [NSLocalizedDescriptionKey: "Helper connection interrupted"]
                    )))
                }
            }
            connection.invalidationHandler = {
                Task {
                    await gate.finish(.failure(NSError(
                        domain: "ControlPower.Helper",
                        code: 6,
                        userInfo: [NSLocalizedDescriptionKey: "Helper connection invalidated"]
                    )))
                }
            }

            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(Self.xpcTimeoutSeconds))
                guard !Task.isCancelled else { return }
                await gate.finish(.failure(NSError(
                    domain: "ControlPower.Helper",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "Helper response timed out"]
                )))
            }
            Task {
                await gate.installTimeoutTask(timeoutTask)
            }

            connection.resume()

            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                Task {
                    await gate.finish(.failure(error))
                }
            }) as? PowerHelperXPCProtocol else {
                Task {
                    await gate.finish(.failure(NSError(
                        domain: "ControlPower.Helper",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Remote proxy unavailable"]
                    )))
                }
                return
            }

            block(proxy) { value, error in
                Task {
                    if let error {
                        await gate.finish(.failure(error))
                        return
                    }
                    guard let value else {
                        await gate.finish(.failure(NSError(
                            domain: "ControlPower.Helper",
                            code: 4,
                            userInfo: [NSLocalizedDescriptionKey: "Missing response payload"]
                        )))
                        return
                    }
                    await gate.finish(.success(value))
                }
            }
        }
    }
}

private actor XPCReplyGate<T: Sendable> {
    private var continuation: CheckedContinuation<T, Error>?
    private var timeoutTask: Task<Void, Never>?
    private let onFinish: @Sendable () -> Void

    init(continuation: CheckedContinuation<T, Error>, onFinish: @escaping @Sendable () -> Void) {
        self.continuation = continuation
        self.onFinish = onFinish
    }

    func installTimeoutTask(_ task: Task<Void, Never>) {
        timeoutTask?.cancel()
        timeoutTask = task
    }

    func finish(_ result: Result<T, Error>) {
        guard let continuation else {
            return
        }
        self.continuation = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil

        timeoutTask?.cancel()
        onFinish()

        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
