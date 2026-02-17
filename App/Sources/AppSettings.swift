import Foundation

struct AppSettings: Codable, Equatable {
    var launchAtLogin: Bool = true
    var autoRegisterDaemonOnLaunch: Bool = true
    var autoRefreshIntervalSeconds: Int = 30
    var promptOnQuitIfChanged: Bool = true
    var showThermalWarning: Bool = true
    var selectedPresetRawValue: Int = PowerPreset.appleDefaults.rawValue
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var settings = AppSettings() {
        didSet { scheduleSave() }
    }

    @Published private(set) var persistenceError: String?

    private let url: URL?
    private var saveTask: Task<Void, Never>?

    init() {
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dir = base.appendingPathComponent("ControlPower", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            url = dir.appendingPathComponent("settings.json")
            load()
        } catch {
            url = nil
            persistenceError = "Settings unavailable: \(error.localizedDescription)"
        }
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        guard copy != settings else { return }
        settings = copy
    }

    private func load() {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            settings = try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            persistenceError = "Failed to load settings: \(error.localizedDescription)"
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
        guard let url else { return }
        do {
            let data = try JSONEncoder().encode(settings)
            try data.write(to: url, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError = "Failed to save settings: \(error.localizedDescription)"
        }
    }
}
