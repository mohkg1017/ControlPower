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

    static func requirementString(for policy: ClientAuthorizationPolicy) -> String? {
        CodeSigningRequirementBuilder.trustedClientRequirementString(
            bundleIdentifier: policy.bundleIdentifier,
            teamIdentifier: policy.teamIdentifier
        )
    }
}

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = HelperService()
    private let authorizationRequirementString: String?

    override init() {
        let policy = AuthorizedClientIdentity.loadPolicy()
        self.authorizationRequirementString = AuthorizedClientIdentity.requirementString(for: policy)
        super.init()
    }

    func configure(listener: NSXPCListener) {
        guard let authorizationRequirementString else {
            return
        }
        if #available(macOS 13.0, *) {
            listener.setConnectionCodeSigningRequirement(authorizationRequirementString)
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard authorizationRequirementString != nil else {
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: PowerHelperXPCProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: PowerHelperConstants.machServiceName)
delegate.configure(listener: listener)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
