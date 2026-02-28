import Foundation
import OSLog
import Synchronization

final class HelperService: NSObject, PowerHelperXPCProtocol, @unchecked Sendable {
    private struct SessionTokenState {
        var tokens: [ObjectIdentifier: String] = [:]
    }

    private struct ConnectionContext {
        let identifier: ObjectIdentifier
        let processIdentifier: pid_t
        let effectiveUserIdentifier: uid_t
    }

    private let logger = Logger(subsystem: "com.moe.controlpower.helper", category: "xpc")
    private let pmsetURL = URL(fileURLWithPath: "/usr/bin/pmset")
    private let pmsetTimeoutSeconds: TimeInterval = 8
    private let idleTimeoutSeconds: TimeInterval = 120
    private let pmsetValidationError: String? = SystemExecutableValidator.validateExecutable(at: URL(fileURLWithPath: "/usr/bin/pmset"))
    private let operationQueue = DispatchQueue(label: "com.moe.controlpower.helper.pmset", qos: .utility)
    private let lastActivity = Mutex(Date())
    private let inFlightRequestCount = Mutex(0)
    private let sessionTokens = Mutex(SessionTokenState())
    private let idleTimer: DispatchSourceTimer

    override init() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.moe.controlpower.helper.idle-watchdog", qos: .background))
        self.idleTimer = timer
        super.init()

        timer.schedule(deadline: .now() + .seconds(Int(idleTimeoutSeconds)), repeating: .seconds(30), leeway: .seconds(10))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let idleDuration = self.lastActivity.withLock { Date().timeIntervalSince($0) }
            let hasInFlightRequests = self.inFlightRequestCount.withLock { $0 > 0 }
            if idleDuration >= self.idleTimeoutSeconds && !hasInFlightRequests {
                exit(EXIT_SUCCESS)
            }
        }
        timer.resume()
    }

    deinit {
        idleTimer.cancel()
    }

    nonisolated func issueSessionToken(_ reply: @escaping (String) -> Void) {
        beginRequest()
        defer { endRequest() }
        guard let context = currentConnectionContext() else {
            reply("")
            return
        }

        let token = UUID().uuidString
        sessionTokens.withLock { $0.tokens[context.identifier] = token }
        logger.info("issued session token for pid \(context.processIdentifier, privacy: .public) uid \(context.effectiveUserIdentifier, privacy: .public)")
        reply(token)
    }

    nonisolated func ping(_ token: String, _ reply: @escaping (String) -> Void) {
        beginRequest()
        defer { endRequest() }
        guard validateSessionToken(token, action: "ping") else {
            reply("unauthorized")
            return
        }
        reply("pong")
    }

    nonisolated func fetchStatus(_ token: String, _ reply: @escaping @Sendable (Bool, Int, Int, String, String) -> Void) {
        beginRequest()
        guard validateSessionToken(token, action: "fetchStatus") else {
            endRequest()
            reply(false, -1, -1, "", "Unauthorized request token")
            return
        }

        operationQueue.async { [self] in
            defer { endRequest() }
            let result = self.runPMSet(arguments: ["-g"])
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
    }

    nonisolated func setDisableSleep(_ enabled: Bool, token: String, _ reply: @escaping @Sendable (Bool, String) -> Void) {
        beginRequest()
        guard validateSessionToken(token, action: "setDisableSleep") else {
            endRequest()
            reply(false, "Unauthorized request token")
            return
        }

        operationQueue.async { [self] in
            defer { endRequest() }
            let result = self.runPMSet(arguments: ["-a", "disablesleep", enabled ? "1" : "0"])
            reply(result.success, result.output)
        }
    }

    nonisolated func restoreDefaults(_ token: String, _ reply: @escaping @Sendable (Bool, String) -> Void) {
        beginRequest()
        guard validateSessionToken(token, action: "restoreDefaults") else {
            endRequest()
            reply(false, "Unauthorized request token")
            return
        }

        operationQueue.async { [self] in
            defer { endRequest() }
            let disableResult = self.runPMSet(arguments: ["-a", "disablesleep", "0"])
            guard disableResult.success else {
                reply(false, disableResult.output)
                return
            }

            let lidResult = self.runPMSet(arguments: ["-a", "lidwake", "1"])
            reply(lidResult.success, lidResult.output)
        }
    }

    nonisolated func clearSessionToken(for connectionIdentifier: ObjectIdentifier) {
        sessionTokens.withLock { $0.tokens[connectionIdentifier] = nil }
    }

    nonisolated private func beginRequest() {
        inFlightRequestCount.withLock { $0 += 1 }
        markActivity()
    }

    nonisolated private func endRequest() {
        inFlightRequestCount.withLock { count in
            if count > 0 {
                count -= 1
            }
        }
    }

    nonisolated private func markActivity() {
        lastActivity.withLock { $0 = Date() }
    }

    nonisolated private func currentConnectionContext() -> ConnectionContext? {
        guard let connection = NSXPCConnection.current() else {
            logger.error("missing current NSXPCConnection context")
            return nil
        }
        return ConnectionContext(
            identifier: ObjectIdentifier(connection),
            processIdentifier: connection.processIdentifier,
            effectiveUserIdentifier: connection.effectiveUserIdentifier
        )
    }

    nonisolated private func validateSessionToken(_ token: String, action: StaticString) -> Bool {
        guard let context = currentConnectionContext() else {
            return false
        }

        let isValid = sessionTokens.withLock { state -> Bool in
            guard let expectedToken = state.tokens[context.identifier], expectedToken == token else {
                return false
            }
            state.tokens[context.identifier] = nil
            return true
        }

        if isValid {
            logger.info("accepted token for \(action, privacy: .public) from pid \(context.processIdentifier, privacy: .public)")
            return true
        }

        logger.error("rejected token for \(action, privacy: .public) from pid \(context.processIdentifier, privacy: .public)")
        return false
    }

    nonisolated private func runPMSet(arguments: [String]) -> (success: Bool, output: String) {
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
