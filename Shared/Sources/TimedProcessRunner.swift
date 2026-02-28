import Foundation
import Synchronization

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

private struct TimedProcessCancellationState {
    var processIdentifier: pid_t?
    var isCancelled = false
}

private struct TimedProcessOutputCaptureState {
    var output = ""
}

public final class TimedProcessCancellation: Sendable {
    private let state = Mutex(TimedProcessCancellationState())

    public init() {}

    public var isCancelled: Bool {
        state.withLock { $0.isCancelled }
    }

    func install(processIdentifier: pid_t) -> Bool {
        state.withLock { state in
            guard !state.isCancelled else {
                return false
            }
            state.processIdentifier = processIdentifier
            return true
        }
    }

    func clearProcessIdentifier() {
        state.withLock { $0.processIdentifier = nil }
    }

    public func cancel() {
        let processIdentifier = state.withLock { state -> pid_t? in
            state.isCancelled = true
            let processIdentifier = state.processIdentifier
            // Clear before signaling to reduce PID-reuse race windows.
            state.processIdentifier = nil
            return processIdentifier
        }
        guard let processIdentifier else { return }
        kill(processIdentifier, SIGTERM)
    }
}

public struct TimedProcessRunner: Sendable {
    public let executableURL: URL
    public let timeoutSeconds: TimeInterval
    private let outputByteLimit = 262_144

    public init(executableURL: URL, timeoutSeconds: TimeInterval = 8) {
        self.executableURL = executableURL
        self.timeoutSeconds = timeoutSeconds
    }

    public func run(
        arguments: [String],
        cancellation: TimedProcessCancellation? = nil,
        onProcessStarted: (@Sendable () -> Void)? = nil
    ) -> TimedProcessResult {
        if cancellation?.isCancelled == true {
            return cancelledResult()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let terminationGroup = DispatchGroup()
        terminationGroup.enter()
        process.terminationHandler = { _ in
            cancellation?.clearProcessIdentifier()
            terminationGroup.leave()
        }

        do {
            try process.run()
            onProcessStarted?()
        } catch {
            return TimedProcessResult(success: false, output: error.localizedDescription, timedOut: false)
        }

        let outputCaptureState = Mutex(TimedProcessOutputCaptureState())
        let outputReadGroup = DispatchGroup()
        outputReadGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let output = Self.readOutput(from: outputPipe, maximumBytes: outputByteLimit)
            outputCaptureState.withLock { $0.output = output }
            outputReadGroup.leave()
        }

        if let cancellation, !cancellation.install(processIdentifier: process.processIdentifier) {
            _ = terminate(process: process, terminationGroup: terminationGroup)
            waitForOutputCapture(outputReadGroup, pipe: outputPipe)
            return cancelledResult()
        }

        let finishedInTime = terminationGroup.wait(timeout: .now() + timeoutSeconds) == .success
        if !finishedInTime {
            let processStopped = terminate(process: process, terminationGroup: terminationGroup)
            cancellation?.clearProcessIdentifier()
            waitForOutputCapture(outputReadGroup, pipe: outputPipe)

            if !processStopped {
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

        cancellation?.clearProcessIdentifier()
        waitForOutputCapture(outputReadGroup, pipe: outputPipe)
        let output = outputCaptureState.withLock { $0.output }
        if cancellation?.isCancelled == true {
            return cancelledResult()
        }
        return TimedProcessResult(success: process.terminationStatus == 0, output: output, timedOut: false)
    }

    private func terminate(
        process: Process,
        terminationGroup: DispatchGroup
    ) -> Bool {
        if process.isRunning {
            process.terminate()
        }
        var processStopped = terminationGroup.wait(timeout: .now() + 1) == .success || !process.isRunning

        if !processStopped && process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            processStopped = terminationGroup.wait(timeout: .now() + 1) == .success || !process.isRunning
        }

        return processStopped
    }

    private func waitForOutputCapture(_ group: DispatchGroup, pipe: Pipe) {
        if group.wait(timeout: .now() + 1) == .success {
            return
        }
        pipe.fileHandleForReading.closeFile()
        _ = group.wait(timeout: .now() + 1)
    }

    private static func readOutput(from pipe: Pipe, maximumBytes: Int) -> String {
        let handle = pipe.fileHandleForReading
        defer { handle.closeFile() }

        var outputData = Data()
        outputData.reserveCapacity(min(maximumBytes, 4096))
        var truncated = false

        while true {
            let chunk = handle.availableData
            guard !chunk.isEmpty else { break }

            let remaining = maximumBytes - outputData.count
            if remaining <= 0 {
                truncated = true
                break
            }

            if chunk.count <= remaining {
                outputData.append(chunk)
            } else {
                outputData.append(chunk.prefix(remaining))
                truncated = true
                break
            }
        }

        var output = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if truncated {
            let suffix = "[output truncated at \(maximumBytes) bytes]"
            output = output.isEmpty ? suffix : "\(output)\n\(suffix)"
        }
        return output
    }

    private func cancelledResult() -> TimedProcessResult {
        TimedProcessResult(success: false, output: "Command cancelled", timedOut: false)
    }

    private func formatTimeout(_ seconds: TimeInterval) -> String {
        if seconds.rounded() == seconds {
            return String(Int(seconds))
        }
        return String(format: "%.1f", seconds)
    }
}
