import Foundation

public struct TimedProcessResult: Equatable, Sendable {
    public let success: Bool
    public let output: String
    public let timedOut: Bool

    public init(success: Bool, output: String, timedOut: Bool) {
        self.success = success
        self.output = output
        self.timedOut = timedOut
    }
}

public struct TimedProcessRunner: Sendable {
    public let executableURL: URL
    public let timeoutSeconds: TimeInterval

    public init(executableURL: URL, timeoutSeconds: TimeInterval = 8) {
        self.executableURL = executableURL
        self.timeoutSeconds = timeoutSeconds
    }

    public func run(arguments: [String]) -> TimedProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let exitSignal = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            exitSignal.signal()
        }

        do {
            try process.run()
        } catch {
            return TimedProcessResult(success: false, output: error.localizedDescription, timedOut: false)
        }

        let finishedInTime = exitSignal.wait(timeout: .now() + timeoutSeconds) == .success
        if !finishedInTime {
            var processStopped = false
            if process.isRunning {
                process.terminate()
            }
            processStopped = exitSignal.wait(timeout: .now() + 1) == .success || !process.isRunning

            if !processStopped && process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                processStopped = exitSignal.wait(timeout: .now() + 1) == .success || !process.isRunning
            }

            if !processStopped {
                outputPipe.fileHandleForReading.closeFile()
                return TimedProcessResult(
                    success: false,
                    output: "Command timed out after \(formatTimeout(timeoutSeconds)) seconds",
                    timedOut: true
                )
            }

            return TimedProcessResult(
                success: false,
                output: "Command timed out after \(formatTimeout(timeoutSeconds)) seconds",
                timedOut: true
            )
        }

        let output = readOutput(from: outputPipe)
        return TimedProcessResult(success: process.terminationStatus == 0, output: output, timedOut: false)
    }

    private func readOutput(from pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func formatTimeout(_ seconds: TimeInterval) -> String {
        if seconds.rounded() == seconds {
            return String(Int(seconds))
        }
        return String(format: "%.1f", seconds)
    }
}
