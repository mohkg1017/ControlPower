import Foundation

@MainActor
final class HelperService: NSObject, @preconcurrency PowerHelperXPCProtocol {
    private let pmsetURL = URL(fileURLWithPath: "/usr/bin/pmset")
    private let pmsetTimeoutSeconds: TimeInterval = 8
    private lazy var pmsetValidationError: String? = SystemExecutableValidator.validateExecutable(at: pmsetURL)

    func ping(_ reply: @escaping (String) -> Void) {
        reply("pong")
    }

    func fetchStatus(_ reply: @escaping (Bool, Int, Int, String, String) -> Void) {
        let result = runPMSet(arguments: ["-g"])
        guard result.success else {
            reply(false, -1, -1, "", result.output)
            return
        }

        let snapshot = PMSetParser.parse(result.output)
        reply(
            true,
            snapshot.disableSleep == nil ? -1 : (snapshot.disableSleep == true ? 1 : 0),
            snapshot.lidWake == nil ? -1 : (snapshot.lidWake == true ? 1 : 0),
            snapshot.summary,
            ""
        )
    }

    func setDisableSleep(_ enabled: Bool, _ reply: @escaping (Bool, String) -> Void) {
        let result = runPMSet(arguments: ["-a", "disablesleep", enabled ? "1" : "0"])
        reply(result.success, result.output)
    }

    func restoreDefaults(_ reply: @escaping (Bool, String) -> Void) {
        let disableResult = runPMSet(arguments: ["-a", "disablesleep", "0"])
        guard disableResult.success else {
            reply(false, disableResult.output)
            return
        }

        let lidResult = runPMSet(arguments: ["-a", "lidwake", "1"])
        reply(lidResult.success, lidResult.output)
    }

    private func runPMSet(arguments: [String]) -> (success: Bool, output: String) {
        if let pmsetValidationError {
            return (false, pmsetValidationError)
        }

        let runner = TimedProcessRunner(executableURL: pmsetURL, timeoutSeconds: pmsetTimeoutSeconds)
        let result = runner.run(arguments: arguments)
        if result.timedOut {
            return (false, "pmset command timed out after \(Int(pmsetTimeoutSeconds)) seconds")
        }
        return (result.success, result.output)
    }

}
