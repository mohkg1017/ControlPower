import Foundation
import Security

public enum PowerHelperConstants {
    public static let daemonPlistName = "com.moe.controlpower.helper.plist"
    public static let daemonLabel = "com.moe.controlpower.helper"
    public static let machServiceName = "com.moe.controlpower.helper.mach"
    public static let helperExecutableIdentifier = "com.moe.controlpower.helper.bin"
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

public enum CodeSigningRequirementBuilder {
    public static func signedBinaryRequirementString(
        identifier: String,
        teamIdentifier: String?
    ) -> String {
        var requirement = "anchor apple generic and identifier \"\(escapeLiteral(identifier))\""
        if let teamIdentifier {
            requirement += " and certificate leaf[subject.OU] = \"\(escapeLiteral(teamIdentifier))\""
        }
        return requirement
    }

    public static func trustedClientRequirementString(
        bundleIdentifier: String,
        teamIdentifier: String?
    ) -> String? {
        guard let teamIdentifier else {
            return nil
        }

        return signedBinaryRequirementString(identifier: bundleIdentifier, teamIdentifier: teamIdentifier)
    }

    public static func helperExecutableRequirementString(teamIdentifier: String?) -> String {
        signedBinaryRequirementString(
            identifier: PowerHelperConstants.helperExecutableIdentifier,
            teamIdentifier: teamIdentifier
        )
    }

    public static func requirement(from requirementString: String) -> SecRequirement? {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(requirementString as CFString, SecCSFlags(), &requirement)
        guard status == errSecSuccess, let requirement else {
            return nil
        }
        return requirement
    }

    private static func escapeLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
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
        var disableSleep: Bool?
        var lidWake: Bool?

        for line in text.split(whereSeparator: \.isNewline) {
            if disableSleep == nil {
                disableSleep = parseBooleanValue(key: "SleepDisabled", inLine: line)
            }
            if lidWake == nil {
                lidWake = parseBooleanValue(key: "lidwake", inLine: line)
            }
            if disableSleep != nil && lidWake != nil {
                break
            }
        }

        return PMSetSnapshot(
            disableSleep: disableSleep,
            lidWake: lidWake,
            summary: text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func parseBooleanValue(key: String, inLine line: Substring) -> Bool? {
        let trimmed = line.drop(while: \.isWhitespace)
        guard trimmed.hasPrefix(key) else {
            return nil
        }

        let valueSlice = trimmed.dropFirst(key.count).drop(while: \.isWhitespace)
        guard let value = valueSlice.first else {
            return nil
        }

        if value == "1" { return true }
        if value == "0" { return false }
        return nil
    }
}

enum SystemExecutableValidator {
    private static let pmsetRequirementString = "anchor apple and identifier \"com.apple.pmset\""
    private static let launchctlRequirementString = "anchor apple and identifier \"com.apple.xpc.launchctl\""

    static func validateExecutable(at url: URL) -> String? {
        validateExecutable(
            at: url,
            executableName: "pmset",
            requirementString: pmsetRequirementString
        )
    }

    static func validateLaunchctlExecutable(at url: URL) -> String? {
        validateExecutable(
            at: url,
            executableName: "launchctl",
            requirementString: launchctlRequirementString
        )
    }

    static func validateControlPowerHelperExecutable(
        at url: URL,
        teamIdentifier: String?
    ) -> String? {
        validateExecutable(
            at: url,
            executableName: "ControlPowerHelper",
            requirementString: CodeSigningRequirementBuilder.helperExecutableRequirementString(teamIdentifier: teamIdentifier)
        )
    }

    private static func validateExecutable(
        at url: URL,
        executableName: String,
        requirementString: String
    ) -> String? {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true else {
                return "\(executableName) executable is not a regular file"
            }
            guard values.isExecutable == true else {
                return "\(executableName) executable is not marked executable"
            }
            guard values.isSymbolicLink != true else {
                return "\(executableName) executable must not be a symlink"
            }
        } catch {
            return "Failed to read \(executableName) file attributes: \(error.localizedDescription)"
        }

        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            return "Failed to load \(executableName) code signature (\(createStatus))"
        }

        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(requirementString as CFString, SecCSFlags(), &requirement)
        guard requirementStatus == errSecSuccess, let requirement else {
            return "Failed to build \(executableName) code requirement (\(requirementStatus))"
        }

        let validateStatus = SecStaticCodeCheckValidity(staticCode, SecCSFlags(), requirement)
        guard validateStatus == errSecSuccess else {
            let message = (SecCopyErrorMessageString(validateStatus, nil) as String?) ?? "unknown signature error"
            return "\(executableName) signature validation failed: \(message)"
        }

        return nil
    }
}

enum ProcessSigningIdentity {
    static func currentTeamIdentifier() -> String? {
        var selfCode: SecCode?
        let selfStatus = SecCodeCopySelf(SecCSFlags(), &selfCode)
        guard selfStatus == errSecSuccess, let selfCode else {
            return nil
        }

        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(selfCode, SecCSFlags(), &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            return nil
        }

        var signingInfo: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInfo
        )
        guard infoStatus == errSecSuccess,
              let signingInfo = signingInfo as? [String: Any] else {
            return nil
        }
        return signingInfo[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

struct HelperConnectionAuthorizationPolicy: Sendable {
    let hasSigningRequirement: Bool
    let consoleUserIdentifier: uid_t?

    func allowsConnection(effectiveUserIdentifier: uid_t) -> Bool {
        guard hasSigningRequirement else {
            return false
        }
        guard let consoleUserIdentifier else {
            return false
        }
        return effectiveUserIdentifier == consoleUserIdentifier
    }
}

struct OneTimeSessionTokenStore: Sendable {
    private var tokens: [ObjectIdentifier: String] = [:]

    mutating func issueToken(for connectionIdentifier: ObjectIdentifier) -> String {
        let token = UUID().uuidString
        tokens[connectionIdentifier] = token
        return token
    }

    mutating func consumeToken(_ token: String, for connectionIdentifier: ObjectIdentifier) -> Bool {
        guard let expectedToken = tokens[connectionIdentifier], expectedToken == token else {
            return false
        }
        tokens[connectionIdentifier] = nil
        return true
    }

    mutating func clearToken(for connectionIdentifier: ObjectIdentifier) {
        tokens[connectionIdentifier] = nil
    }
}
