import Foundation
import Security

public enum PowerHelperConstants {
    public static let daemonPlistName = "com.moe.controlpower.helper.plist"
    public static let daemonLabel = "com.moe.controlpower.helper"
    public static let machServiceName = "com.moe.controlpower.helper.mach"
}

public struct ClientAuthorizationPolicy: Sendable {
    public let bundleIdentifier: String
    public let teamIdentifier: String?

    public init(bundleIdentifier: String, teamIdentifier: String?) {
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
    }

    public func isAuthorizedClient(bundleIdentifier: String, teamIdentifier: String?) -> Bool {
        guard bundleIdentifier == self.bundleIdentifier else {
            return false
        }
        guard let expectedTeamIdentifier = self.teamIdentifier else {
            return false
        }
        return teamIdentifier == expectedTeamIdentifier
    }
}

public struct PMSetSnapshot: Equatable, Sendable {
    public var disableSleep: Bool?
    public var lidWake: Bool?
    public var summary: String

    public init(disableSleep: Bool?, lidWake: Bool?, summary: String) {
        self.disableSleep = disableSleep
        self.lidWake = lidWake
        self.summary = summary
    }
}

public enum PMSetParser {
    public static func parse(_ text: String) -> PMSetSnapshot {
        PMSetSnapshot(
            disableSleep: parseBooleanValue(key: "SleepDisabled", in: text),
            lidWake: parseBooleanValue(key: "lidwake", in: text),
            summary: text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func parseBooleanValue(key: String, in text: String) -> Bool? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2 else { continue }
            if parts[0] == key {
                if parts[1] == "1" { return true }
                if parts[1] == "0" { return false }
            }
        }
        return nil
    }
}

enum SystemExecutableValidator {
    static func validateExecutable(at url: URL) -> String? {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true else {
                return "pmset executable is not a regular file"
            }
            guard values.isExecutable == true else {
                return "pmset executable is not marked executable"
            }
            guard values.isSymbolicLink != true else {
                return "pmset executable must not be a symlink"
            }
        } catch {
            return "Failed to read pmset file attributes: \(error.localizedDescription)"
        }

        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            return "Failed to load pmset code signature (\(createStatus))"
        }

        let validateStatus = SecStaticCodeCheckValidity(staticCode, SecCSFlags(), nil)
        guard validateStatus == errSecSuccess else {
            let message = (SecCopyErrorMessageString(validateStatus, nil) as String?) ?? "unknown signature error"
            return "pmset signature validation failed: \(message)"
        }

        return nil
    }
}
