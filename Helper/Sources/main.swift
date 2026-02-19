import Foundation
import Security

private struct AuthorizedClientIdentity {
    static func loadPolicy() -> ClientAuthorizationPolicy {
        ClientAuthorizationPolicy(
            bundleIdentifier: authorizedBundleIdentifier(),
            teamIdentifier: helperTeamIdentifier()
        )
    }

    private static func authorizedBundleIdentifier() -> String {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "ControlPowerAuthorizedClientBundleIdentifier") as? String {
            let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        if let helperBundleIdentifier = Bundle.main.bundleIdentifier,
           helperBundleIdentifier.hasSuffix(".helper.bin") {
            return String(helperBundleIdentifier.dropLast(".helper.bin".count))
        }

        return "com.moe.controlpower"
    }

    private static func helperTeamIdentifier() -> String? {
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

        guard let signingIdentity = signingIdentity(for: staticCode) else {
            return nil
        }
        return signingIdentity.teamIdentifier
    }

    static func signingIdentity(for staticCode: SecStaticCode) -> (identifier: String, teamIdentifier: String?)? {
        var signingInfo: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInfo
        )
        guard infoStatus == errSecSuccess,
              let signingInfo = signingInfo as? [String: Any],
              let signingIdentifier = signingInfo[kSecCodeInfoIdentifier as String] as? String else {
            return nil
        }
        let teamIdentifier = signingInfo[kSecCodeInfoTeamIdentifier as String] as? String
        return (signingIdentifier, teamIdentifier)
    }
}

@MainActor
final class HelperListenerDelegate: NSObject, @preconcurrency NSXPCListenerDelegate {
    private let service = HelperService()
    private let authorizationPolicy = AuthorizedClientIdentity.loadPolicy()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard isAuthorizedClient(newConnection) else {
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: PowerHelperXPCProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }

    private func isAuthorizedClient(_ connection: NSXPCConnection) -> Bool {
        var guestCode: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: connection.processIdentifier)] as CFDictionary
        let copyStatus = SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &guestCode)
        guard copyStatus == errSecSuccess, let guestCode else {
            return false
        }

        let validityStatus = SecCodeCheckValidity(guestCode, SecCSFlags(), nil)
        guard validityStatus == errSecSuccess else {
            return false
        }

        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(guestCode, SecCSFlags(), &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            return false
        }

        guard let signingIdentity = AuthorizedClientIdentity.signingIdentity(for: staticCode) else {
            return false
        }

        return authorizationPolicy.isAuthorizedClient(
            bundleIdentifier: signingIdentity.identifier,
            teamIdentifier: signingIdentity.teamIdentifier
        )
    }
}

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: PowerHelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
