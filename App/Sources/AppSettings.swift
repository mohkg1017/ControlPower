import Foundation

struct AppSettings: Codable, Equatable {
    var launchAtLogin: Bool = true
    var autoRegisterDaemonOnLaunch: Bool = true
    var autoRefreshIntervalSeconds: Int = 60
    var promptOnQuitIfChanged: Bool = true
    var showThermalWarning: Bool = true
    var customTimedKeepAwakeMinutes: Int = 45
    var selectedPresetRawValue: Int = PowerPreset.appleDefaults.rawValue

    init() {}

    private enum CodingKeys: String, CodingKey {
        case launchAtLogin
        case autoRegisterDaemonOnLaunch
        case autoRefreshIntervalSeconds
        case promptOnQuitIfChanged
        case showThermalWarning
        case customTimedKeepAwakeMinutes
        case selectedPresetRawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? true
        autoRegisterDaemonOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .autoRegisterDaemonOnLaunch) ?? true
        autoRefreshIntervalSeconds = min(max(try container.decodeIfPresent(Int.self, forKey: .autoRefreshIntervalSeconds) ?? 60, 60), 900)
        promptOnQuitIfChanged = try container.decodeIfPresent(Bool.self, forKey: .promptOnQuitIfChanged) ?? true
        showThermalWarning = try container.decodeIfPresent(Bool.self, forKey: .showThermalWarning) ?? true
        customTimedKeepAwakeMinutes = min(max(try container.decodeIfPresent(Int.self, forKey: .customTimedKeepAwakeMinutes) ?? 45, 5), 720)
        selectedPresetRawValue = try container.decodeIfPresent(Int.self, forKey: .selectedPresetRawValue) ?? PowerPreset.appleDefaults.rawValue
    }
}

private struct SettingsFileV1: Codable {
    let version: Int
    var settings: AppSettings
}

private struct SettingsVersionProbe: Decodable {
    let version: Int
}

private enum SettingsLoadError: LocalizedError {
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "Unsupported settings file version (\(version))."
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    private static let currentVersion = 1

    @Published private(set) var settings = AppSettings() {
        didSet { scheduleSave() }
    }

    @Published private(set) var persistenceError: String?

    private let settingsURL: URL?
    private let fileManager: FileManager
    private let now: () -> Date
    private var saveTask: Task<Void, Never>?

    init(
        settingsURL: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.now = now
        do {
            self.settingsURL = try settingsURL ?? Self.defaultSettingsURL(fileManager: fileManager)
            load()
        } catch {
            self.settingsURL = nil
            persistenceError = "Settings unavailable: \(error.localizedDescription)"
        }
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        guard copy != settings else { return }
        settings = copy
    }

    func flush() {
        saveTask?.cancel()
        saveNow()
    }

    private func load() {
        guard let settingsURL, fileManager.fileExists(atPath: settingsURL.path) else { return }
        do {
            let data = try Data(contentsOf: settingsURL)
            let decoded = try decodeSettings(from: data)
            settings = decoded.settings
            if decoded.shouldRewrite {
                saveNow()
            }
        } catch SettingsLoadError.unsupportedVersion(let version) {
            persistenceError = "Unsupported settings file version (\(version))."
        } catch {
            let backupURL = settingsURL
                .deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(now().timeIntervalSince1970)).json")
            _ = try? fileManager.moveItem(at: settingsURL, to: backupURL)
            settings = AppSettings()
            saveNow()
            persistenceError = "Failed to load settings: \(error.localizedDescription). Reset to defaults."
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        guard let settingsURL else { return }
        do {
            let payload = SettingsFileV1(version: Self.currentVersion, settings: settings)
            let data = try JSONEncoder().encode(payload)
            try data.write(to: settingsURL, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError = "Failed to save settings: \(error.localizedDescription)"
        }
    }

    private static func defaultSettingsURL(fileManager: FileManager) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("ControlPower", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }

    private func decodeSettings(from data: Data) throws -> (settings: AppSettings, shouldRewrite: Bool) {
        let decoder = JSONDecoder()

        if let versioned = try? decoder.decode(SettingsFileV1.self, from: data) {
            if versioned.version == Self.currentVersion {
                return (versioned.settings, false)
            }
            throw SettingsLoadError.unsupportedVersion(versioned.version)
        }

        if let probe = try? decoder.decode(SettingsVersionProbe.self, from: data),
           probe.version > Self.currentVersion {
            throw SettingsLoadError.unsupportedVersion(probe.version)
        }

        let legacy = try decoder.decode(AppSettings.self, from: data)
        return (legacy, true)
    }
}
