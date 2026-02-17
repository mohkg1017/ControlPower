import SwiftUI

@main
struct ControlPowerApp: App {
    @StateObject private var settingsStore: SettingsStore
    @StateObject private var viewModel: AppViewModel

    init() {
        let store = SettingsStore()
        _settingsStore = StateObject(wrappedValue: store)
        _viewModel = StateObject(wrappedValue: AppViewModel(settingsStore: store))
    }

    var body: some Scene {
        WindowGroup("ControlPower", id: "main") {
            MainView(viewModel: viewModel, settingsStore: settingsStore)
                .frame(minWidth: 680, minHeight: 520)
                .task {
                    viewModel.startup()
                }
        }
        .defaultSize(width: 900, height: 620)
        .commands {
            CommandMenu("Power") {
                Button("Refresh Status") {
                    Task { await viewModel.refreshStatus() }
                }
                .keyboardShortcut("r", modifiers: .command)

                Button((viewModel.snapshot.disableSleep ?? false) ? "Disable Keep Awake" : "Enable Keep Awake") {
                    viewModel.toggleDisableSleep()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button((viewModel.snapshot.lidWake ?? true) ? "Disable Lid Wake" : "Enable Lid Wake") {
                    viewModel.toggleLidWake()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Divider()

                ForEach(PowerPreset.allCases) { preset in
                    Button("Apply \(preset.title)") {
                        viewModel.applyPreset(preset)
                    }
                }
            }

            CommandGroup(replacing: .appTermination) {
                Button("Quit ControlPower") {
                    viewModel.requestQuit()
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }

        MenuBarExtra("ControlPower", systemImage: "bolt.circle") {
            MenuBarPanelView(viewModel: viewModel)
                .frame(width: 340)
        }
        .menuBarExtraStyle(.window)

        Settings {
            AppSettingsView(viewModel: viewModel, settingsStore: settingsStore)
                .frame(width: 540, height: 420)
        }
    }
}
