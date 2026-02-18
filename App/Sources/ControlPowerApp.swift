import SwiftUI

@main
struct ControlPowerApp: App {
    @StateObject private var settingsStore: SettingsStore
    @StateObject private var viewModel: AppViewModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

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
                .disabled(viewModel.isBusy)

                Button((viewModel.snapshot.disableSleep ?? false) ? "Disable Keep Awake" : "Enable Keep Awake") {
                    viewModel.toggleDisableSleep()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!viewModel.helperReadyForCommands || viewModel.isBusy)

                Button((viewModel.snapshot.lidWake ?? true) ? "Disable Lid Wake" : "Enable Lid Wake") {
                    viewModel.toggleLidWake()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!viewModel.helperReadyForCommands || viewModel.isBusy)

                Divider()

                Button("Restore Defaults") {
                    viewModel.restoreDefaults()
                }
                .disabled(!viewModel.helperReadyForCommands || viewModel.isBusy)

                Button("Apply Saved Preset (\(viewModel.selectedPreset.title))") {
                    viewModel.applySelectedPreset()
                }
                .disabled(!viewModel.helperReadyForCommands || viewModel.isBusy)

                ForEach(PowerPreset.allCases) { preset in
                    Button("Apply \(preset.title)") {
                        viewModel.applyPreset(preset)
                    }
                    .disabled(!viewModel.helperReadyForCommands || viewModel.isBusy)
                }

                Divider()

                Menu("Timed Keep Awake") {
                    Button("30 Minutes") {
                        viewModel.startTimedKeepAwake(minutes: 30)
                    }
                    Button("1 Hour") {
                        viewModel.startTimedKeepAwake(minutes: 60)
                    }
                    Button("2 Hours") {
                        viewModel.startTimedKeepAwake(minutes: 120)
                    }
                    Divider()
                    Button("Cancel Timed Session") {
                        viewModel.cancelTimedKeepAwake()
                    }
                    .disabled(viewModel.timedKeepAwakeEndDate == nil)
                }
                .disabled(!viewModel.helperReadyForCommands || viewModel.isBusy)

                Button("Start Custom Timed Keep Awake (\(viewModel.customTimedKeepAwakeMinutes)m)") {
                    viewModel.startCustomTimedKeepAwake()
                }
                .disabled(!viewModel.helperReadyForCommands || viewModel.isBusy)

                Divider()

                Menu("Copy Terminal Command") {
                    ForEach(viewModel.terminalCommands) { item in
                        Button(item.title) {
                            viewModel.copyTerminalCommand(item)
                        }
                    }
                }
            }

            CommandGroup(after: .windowArrangement) {
                Button("Show ControlPower Window") {
                    openWindow(id: "main")
                }
                .keyboardShortcut("0", modifiers: .command)
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(replacing: .appTermination) {
                Button("Quit ControlPower") {
                    viewModel.requestQuit()
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }

        MenuBarExtra("ControlPower", systemImage: menuBarSymbolName) {
            MenuBarPanelView(viewModel: viewModel)
                .frame(width: 340)
        }
        .menuBarExtraStyle(.window)

        Settings {
            AppSettingsView(viewModel: viewModel, settingsStore: settingsStore)
                .frame(width: 540, height: 420)
        }
    }

    private var menuBarSymbolName: String {
        switch viewModel.daemonStatus {
        case .enabled:
            return "bolt.circle.fill"
        case .requiresApproval:
            return "exclamationmark.triangle"
        case .notRegistered, .notFound:
            return "bolt.slash.circle"
        @unknown default:
            return "bolt.circle"
        }
    }
}
