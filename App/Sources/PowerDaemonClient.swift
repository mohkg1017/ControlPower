import Foundation
import ServiceManagement

extension NSXPCConnection: @retroactive @unchecked Sendable {}

struct PowerHelperStatus: Sendable {
    var snapshot: PMSetSnapshot
}

@MainActor
final class PowerDaemonClient {
    private var daemonService: SMAppService {
        SMAppService.daemon(plistName: PowerHelperConstants.daemonPlistName)
    }

    var daemonStatus: SMAppService.Status {
        daemonService.status
    }

    func registerDaemon() throws {
        try daemonService.register()
    }

    func unregisterDaemon() throws {
        try daemonService.unregister()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func setLaunchAtLogin(enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    func fetchStatus() async throws -> PowerHelperStatus {
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
                done(PowerHelperStatus(snapshot: snapshot), nil)
            }
        }
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
            connection.resume()

            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                Task { @MainActor in
                    connection.invalidate()
                    continuation.resume(throwing: error)
                }
            }) as? PowerHelperXPCProtocol else {
                connection.invalidate()
                continuation.resume(throwing: NSError(domain: "ControlPower.Helper", code: 3, userInfo: [NSLocalizedDescriptionKey: "Remote proxy unavailable"]))
                return
            }

            block(proxy) { value, error in
                Task { @MainActor in
                    connection.invalidate()
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let value else {
                        continuation.resume(throwing: NSError(domain: "ControlPower.Helper", code: 4, userInfo: [NSLocalizedDescriptionKey: "Missing response payload"]))
                        return
                    }
                    continuation.resume(returning: value)
                }
            }
        }
    }
}
