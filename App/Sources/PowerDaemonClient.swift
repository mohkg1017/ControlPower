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
    func displaySleepNow() async throws
    func isHelperEnabled() -> Bool
    func setHelperEnabled(_ enabled: Bool) throws
    func isDaemonBroken() -> Bool
    func repairDaemon() async throws
}

public struct PowerDaemonClient: PowerDaemonClientProtocol {
    nonisolated private static let pmsetURL = URL(fileURLWithPath: "/usr/bin/pmset")
    nonisolated private static let launchctlURL = URL(fileURLWithPath: "/bin/launchctl")
    nonisolated private static let xpcTimeoutSeconds: TimeInterval = 18
    nonisolated private static let xpcProbeTimeoutSeconds: TimeInterval = 5
    nonisolated private static let localPMSetTimeoutSeconds: TimeInterval = 8
    nonisolated private static let registrationProbeTimeoutSeconds: TimeInterval = 3
    nonisolated private static let pmsetValidationError = SystemExecutableValidator.validateExecutable(at: pmsetURL)
    nonisolated private static let expectedProgramIdentifier = "Contents/Resources/ControlPowerHelper"

    public init() {}

    private var daemonService: SMAppService {
        SMAppService.daemon(plistName: PowerHelperConstants.daemonPlistName)
    }

    nonisolated static func helperStatusAllowsWrites(_ status: SMAppService.Status) -> Bool {
        status == .enabled
    }

    public func registerDaemonIfNeeded() throws {
        switch daemonService.status {
        case .notRegistered, .notFound:
            try daemonService.register()
        case .enabled:
            return
        case .requiresApproval:
            return
        @unknown default:
            return
        }
    }

    public func isHelperEnabled() -> Bool {
        Self.helperStatusAllowsWrites(daemonService.status)
    }

    public func setHelperEnabled(_ enabled: Bool) throws {
        if enabled {
            try daemonService.register()
        } else {
            try daemonService.unregister()
        }
    }

    public func isDaemonBroken() -> Bool {
        guard daemonService.status == .enabled else { return false }
        let result = TimedProcessRunner(
            executableURL: Self.launchctlURL,
            timeoutSeconds: Self.registrationProbeTimeoutSeconds
        ).run(arguments: ["print", "system/\(PowerHelperConstants.daemonLabel)"])
        guard result.success else { return false }
        return result.output.contains("spawn failed") || result.output.contains("EX_CONFIG")
    }

    public func repairDaemon() async throws {
        await bootoutDaemon()
        try? await daemonService.unregister()
        try? await Task.sleep(for: .seconds(1))
        try daemonService.register()
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
        if let pmsetValidationError = Self.pmsetValidationError {
            throw NSError(
                domain: "ControlPower.LocalPMSet",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: pmsetValidationError]
            )
        }
        let result = await Task.detached(priority: .userInitiated) {
            TimedProcessRunner(executableURL: Self.pmsetURL, timeoutSeconds: Self.localPMSetTimeoutSeconds)
                .run(arguments: ["displaysleepnow"])
        }.value
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
        guard !isReachable else {
            return
        }

        throw NSError(
            domain: "ControlPower.Helper",
            code: 8,
            userInfo: [NSLocalizedDescriptionKey: "Write actions need the ControlPower helper approved in System Settings > Login Items. Current helper status: \(daemonStatusDescription(status))."]
        )
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

    private func needsDaemonRefresh() -> Bool {
        let result = TimedProcessRunner(
            executableURL: Self.launchctlURL,
            timeoutSeconds: Self.registrationProbeTimeoutSeconds
        ).run(arguments: ["print", "system/\(PowerHelperConstants.daemonLabel)"])
        guard result.success else {
            return false
        }

        if result.output.contains("needs LWCR update") {
            return true
        }

        if result.output.contains("job state = spawn failed") {
            return true
        }

        guard let identifier = registeredProgramIdentifier(from: result.output) else {
            return false
        }
        return identifier != Self.expectedProgramIdentifier
    }

    private func registeredProgramIdentifier(from output: String) -> String? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "program identifier = "
            guard line.hasPrefix(prefix) else {
                continue
            }
            let value = String(line.dropFirst(prefix.count))
            if let modeStart = value.range(of: " (mode:") {
                return String(value[..<modeStart.lowerBound])
            }
            return value
        }
        return nil
    }

    private func performWrite(_ writeOperation: @escaping () async throws -> Void) async throws {
        try await ensureHelperReadyForWrites()
        try await writeOperation()
    }

    nonisolated private func bootoutDaemon() async {
        _ = await Task.detached(priority: .utility) {
            TimedProcessRunner(
                executableURL: Self.launchctlURL,
                timeoutSeconds: Self.registrationProbeTimeoutSeconds
            ).run(arguments: ["bootout", "system/\(PowerHelperConstants.daemonLabel)"])
        }.value
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
        timeoutSeconds: TimeInterval = Self.xpcTimeoutSeconds,
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
                gate.finish(.failure(NSError(
                    domain: "ControlPower.Helper",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Helper connection interrupted"]
                )))
            }
            connection.invalidationHandler = {
                gate.finish(.failure(NSError(
                    domain: "ControlPower.Helper",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Helper connection invalidated"]
                )))
            }

            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                guard !Task.isCancelled else { return }
                gate.finish(.failure(NSError(
                    domain: "ControlPower.Helper",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "Helper response timed out after \(Int(timeoutSeconds.rounded())) seconds"]
                )))
            }
            gate.installTimeoutTask(timeoutTask)

            connection.resume()

            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                gate.finish(.failure(error))
            }) as? PowerHelperXPCProtocol else {
                gate.finish(.failure(NSError(
                    domain: "ControlPower.Helper",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Remote proxy unavailable"]
                )))
                return
            }

            block(proxy) { value, error in
                if let error {
                    gate.finish(.failure(error))
                    return
                }
                guard let value else {
                    gate.finish(.failure(NSError(
                        domain: "ControlPower.Helper",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Missing response payload"]
                    )))
                    return
                }
                gate.finish(.success(value))
            }
        }
    }
}

final class XPCReplyGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var timeoutTask: Task<Void, Never>?
    private let onFinish: @Sendable () -> Void

    init(continuation: CheckedContinuation<T, Error>, onFinish: @escaping @Sendable () -> Void) {
        self.continuation = continuation
        self.onFinish = onFinish
    }

    func installTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        timeoutTask?.cancel()
        timeoutTask = task
        lock.unlock()
    }

    func finish(_ result: Result<T, Error>) {
        let continuation: CheckedContinuation<T, Error>
        let timeoutTask: Task<Void, Never>?

        lock.lock()
        guard let currentContinuation = self.continuation else {
            lock.unlock()
            return
        }
        continuation = currentContinuation
        self.continuation = nil
        timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()

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
