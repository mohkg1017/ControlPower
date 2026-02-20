import Foundation

@objc public protocol PowerHelperXPCProtocol {
    func ping(_ reply: @escaping (String) -> Void)
    func fetchStatus(_ reply: @escaping (Bool, Int, Int, String, String) -> Void)
    func setDisableSleep(_ enabled: Bool, _ reply: @escaping (Bool, String) -> Void)
    func restoreDefaults(_ reply: @escaping (Bool, String) -> Void)
    // Intentionally no `displaySleepNow`: this call does not require elevated privileges.
}
