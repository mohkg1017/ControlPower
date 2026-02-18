import Foundation

public enum PowerHelperConstants {
    public static let daemonPlistName = "com.moe.controlpower.helper.plist"
    public static let daemonLabel = "com.moe.controlpower.helper"
    public static let machServiceName = "com.moe.controlpower.helper.mach"
    public static let mainAppBundleIdentifier = "com.moe.controlpower"
    public static let mainAppTeamIdentifier = "45954WVVY3"
}

public enum PowerPreset: Int, CaseIterable, Identifiable, Sendable {
    case keepAwake = 1
    case deskMode = 2
    case appleDefaults = 3

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .keepAwake:
            "Keep Awake"
        case .deskMode:
            "Desk Mode"
        case .appleDefaults:
            "Apple Defaults"
        }
    }

    public var detail: String {
        switch self {
        case .keepAwake:
            "disablesleep=1, lidwake=0"
        case .deskMode:
            "disablesleep=1, lidwake=1"
        case .appleDefaults:
            "disablesleep=0, lidwake=1"
        }
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
