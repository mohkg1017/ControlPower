import Foundation

@objc public protocol PowerHelperXPCProtocol {
    func issueSessionToken(_ reply: @escaping (String) -> Void)
    func ping(_ token: String, _ reply: @escaping (String) -> Void)
    func fetchStatus(_ token: String, _ reply: @escaping @Sendable (Bool, Int, Int, String, String) -> Void)
    func setDisableSleep(_ enabled: Bool, token: String, _ reply: @escaping @Sendable (Bool, String) -> Void)
    func restoreDefaults(_ token: String, _ reply: @escaping @Sendable (Bool, String) -> Void)
    // Intentionally no `displaySleepNow`: this call does not require elevated privileges.
}
