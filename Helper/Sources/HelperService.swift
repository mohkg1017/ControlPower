import Foundation

final class HelperService: NSObject, PowerHelperXPCProtocol {
    private let pmsetURL = URL(fileURLWithPath: "/usr/bin/pmset")

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

    func setLidWake(_ enabled: Bool, _ reply: @escaping (Bool, String) -> Void) {
        let result = runPMSet(arguments: ["-a", "lidwake", enabled ? "1" : "0"])
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

    func applyPreset(_ presetRawValue: Int, _ reply: @escaping (Bool, String) -> Void) {
        guard let preset = PowerPreset(rawValue: presetRawValue) else {
            reply(false, "Unsupported preset")
            return
        }

        let commands: [[String]]
        switch preset {
        case .keepAwake:
            commands = [["-a", "disablesleep", "1"], ["-a", "lidwake", "0"]]
        case .deskMode:
            commands = [["-a", "disablesleep", "1"], ["-a", "lidwake", "1"]]
        case .appleDefaults:
            commands = [["-a", "disablesleep", "0"], ["-a", "lidwake", "1"]]
        }

        for command in commands {
            let result = runPMSet(arguments: command)
            if !result.success {
                reply(false, result.output)
                return
            }
        }

        reply(true, "Applied \(preset.title)")
    }

    private func runPMSet(arguments: [String]) -> (success: Bool, output: String) {
        let process = Process()
        process.executableURL = pmsetURL
        process.arguments = arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (process.terminationStatus == 0, output)
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
