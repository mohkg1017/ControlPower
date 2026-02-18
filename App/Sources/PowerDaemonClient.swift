import Foundation
import ServiceManagement

extension NSXPCConnection: @retroactive @unchecked Sendable {}

enum PowerStatusSource: Sendable, Equatable {
    case helper
    case localFallback
}

struct PowerHelperStatus: Sendable {
    var snapshot: PMSetSnapshot
    var source: PowerStatusSource
}

@MainActor
protocol PowerDaemonClientProtocol {
    var daemonStatus: SMAppService.Status { get }
    func registerDaemon() throws
    func unregisterDaemon() throws
    func openLoginItemsSettings()
    func setLaunchAtLogin(enabled: Bool) throws
    func fetchStatus() async throws -> PowerHelperStatus
    func setDisableSleep(_ enabled: Bool) async throws
    func setLidWake(_ enabled: Bool) async throws
    func restoreDefaults() async throws
    func applyPreset(_ preset: PowerPreset) async throws
}

@MainActor
final class PowerDaemonClient: PowerDaemonClientProtocol {
    nonisolated private static let pmsetURL = URL(fileURLWithPath: "/usr/bin/pmset")
    nonisolated private static let xpcTimeoutSeconds: TimeInterval = 8

    private var daemonService: SMAppService {
        SMAppService.daemon(plistName: PowerHelperConstants.daemonPlistName)
    }

    var daemonStatus: SMAppService.Status {
        daemonService.status
    }

    func registerDaemon() throws {
        switch daemonService.status {
        case .notRegistered, .notFound:
            try daemonService.register()
        case .enabled, .requiresApproval:
            return
        @unknown default:
            return
        }
    }

    func unregisterDaemon() throws {
        switch daemonService.status {
        case .enabled, .requiresApproval:
            try daemonService.unregister()
        case .notRegistered, .notFound:
            return
        @unknown default:
            return
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func setLaunchAtLogin(enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            switch service.status {
            case .notRegistered, .notFound:
                try service.register()
            case .enabled, .requiresApproval:
                return
            @unknown default:
                return
            }
        } else {
            switch service.status {
            case .enabled, .requiresApproval:
                try service.unregister()
            case .notRegistered, .notFound:
                return
            @unknown default:
                return
            }
        }
    }

    func fetchStatus() async throws -> PowerHelperStatus {
        if daemonStatus != .enabled {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                try Self.fetchLocalPMSetSnapshot()
            }.value
            return PowerHelperStatus(snapshot: snapshot, source: .localFallback)
        }

        do {
            return try await fetchStatusFromHelper()
        } catch {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                try Self.fetchLocalPMSetSnapshot()
            }.value
            return PowerHelperStatus(snapshot: snapshot, source: .localFallback)
        }
    }

    private func fetchStatusFromHelper() async throws -> PowerHelperStatus {
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
        let process = Process()
        process.executableURL = pmsetURL
        process.arguments = ["-g"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        process.waitUntilExit()

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "ControlPower.LocalPMSet",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: output.isEmpty ? "pmset -g failed" : output]
            )
        }

        return PMSetParser.parse(output)
    }

    func setDisableSleep(_ enabled: Bool) async throws {
        try await simpleCall { proxy, done in
            proxy.setDisableSleep(enabled) { success, message in
                done(success, message)
            }
        }
    }

    func setLidWake(_ enabled: Bool) async throws {
        try await simpleCall { proxy, done in
            proxy.setLidWake(enabled) { success, message in
                done(success, message)
            }
        }
    }

    func restoreDefaults() async throws {
        try await simpleCall { proxy, done in
            proxy.restoreDefaults { success, message in
                done(success, message)
            }
        }
    }

    func applyPreset(_ preset: PowerPreset) async throws {
        try await simpleCall { proxy, done in
            proxy.applyPreset(preset.rawValue) { success, message in
                done(success, message)
            }
        }
    }

    private func simpleCall(_ action: @escaping @Sendable (PowerHelperXPCProtocol, @escaping (Bool, String) -> Void) -> Void) async throws {
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

    private func withConnection<T: Sendable>(
        _ block: @escaping @Sendable (PowerHelperXPCProtocol, @escaping @Sendable (T?, Error?) -> Void) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: PowerHelperConstants.machServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: PowerHelperXPCProtocol.self)
            let gate = XPCReplyGate(continuation: continuation) {
                connection.invalidate()
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

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.xpcTimeoutSeconds) {
                gate.finish(.failure(NSError(
                    domain: "ControlPower.Helper",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "Helper response timed out"]
                )))
            }

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

private final class XPCReplyGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private let onFinish: @Sendable () -> Void

    init(continuation: CheckedContinuation<T, Error>, onFinish: @escaping @Sendable () -> Void) {
        self.continuation = continuation
        self.onFinish = onFinish
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()

        onFinish()

        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
