import SwiftUI

struct AppSettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var settingsStore: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { settingsStore.settings.launchAtLogin },
                    set: { value in
                        settingsStore.update { $0.launchAtLogin = value }
                        viewModel.applySettings()
                    }
                ))
                settingDetail("Starts ControlPower when you sign in so menu bar controls are available immediately.")

                Toggle("Auto-register privileged helper on launch", isOn: Binding(
                    get: { settingsStore.settings.autoRegisterDaemonOnLaunch },
                    set: { value in
                        settingsStore.update { $0.autoRegisterDaemonOnLaunch = value }
                    }
                ))
                settingDetail("Attempts helper registration at launch. Approval may still be required in Login Items.")

                Stepper(value: Binding(
                    get: { settingsStore.settings.autoRefreshIntervalSeconds },
                    set: { value in
                        settingsStore.update { $0.autoRefreshIntervalSeconds = min(max(value, 60), 900) }
                        viewModel.applySettings()
                    }
                ), in: 60...900, step: 5) {
                    Text("Auto-refresh every \(settingsStore.settings.autoRefreshIntervalSeconds) seconds")
                }
                settingDetail("Controls how often status is refreshed from pmset and helper state.")
            } header: {
                Label("Startup", systemImage: "power")
            }

            Section {
                Toggle("Prompt on quit when settings changed", isOn: Binding(
                    get: { settingsStore.settings.promptOnQuitIfChanged },
                    set: { value in
                        settingsStore.update { $0.promptOnQuitIfChanged = value }
                    }
                ))
                settingDetail("Warns before quitting if your current power state differs from launch.")

                Toggle("Show thermal warning", isOn: Binding(
                    get: { settingsStore.settings.showThermalWarning },
                    set: { value in
                        settingsStore.update { $0.showThermalWarning = value }
                    }
                ))
                settingDetail("Shows a reminder that disabling sleep can increase heat during long sessions.")
            } header: {
                Label("Safety", systemImage: "shield")
            }

            Section {
                Picker("Saved preset", selection: Binding(
                    get: { viewModel.selectedPreset },
                    set: { viewModel.setSelectedPreset($0) }
                )) {
                    ForEach(PowerPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }

                Stepper(value: Binding(
                    get: { viewModel.customTimedKeepAwakeMinutes },
                    set: { viewModel.setCustomTimedKeepAwakeMinutes($0) }
                ), in: 5...720, step: 5) {
                    Text("Custom timed keep awake: \(viewModel.customTimedKeepAwakeMinutes) minutes")
                }

                Button("Apply saved preset now") {
                    viewModel.applySelectedPreset()
                }
                .disabled(viewModel.isBusy || !viewModel.helperReadyForCommands)
                settingDetail("Applies the selected preset immediately using the privileged helper.")
                settingDetail("Use Timed Keep Awake in the main window or menu bar for temporary sessions with automatic restore.")
            } header: {
                Label("Power", systemImage: "slider.horizontal.3")
            }

            Section {
                LabeledContent("Status") {
                    Label(viewModel.daemonStatusText(), systemImage: helperStatusSymbol)
                        .foregroundStyle(helperStatusTint)
                }

                ControlGroup {
                    Button("Register") {
                        viewModel.registerDaemonIfNeeded()
                    }
                    .disabled(viewModel.daemonStatus == .enabled || viewModel.daemonStatus == .requiresApproval)
                    Button("Unregister") {
                        viewModel.unregisterDaemon()
                    }
                    .disabled(viewModel.daemonStatus == .notRegistered || viewModel.daemonStatus == .notFound)
                    Button("Open Login Items") {
                        viewModel.openLoginItemsSettings()
                    }
                }
                settingDetail("Use Login Items to approve, inspect, or remove the helper after registration.")
            } header: {
                Label("Helper", systemImage: "lock.shield")
            }

            if let error = settingsStore.persistenceError {
                Section("Persistence") {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding(14)
    }

    private var helperStatusSymbol: String {
        switch viewModel.daemonStatus {
        case .enabled:
            return "checkmark.seal.fill"
        case .requiresApproval:
            return "exclamationmark.triangle.fill"
        case .notRegistered, .notFound:
            return "xmark.seal"
        @unknown default:
            return "questionmark.circle"
        }
    }

    private var helperStatusTint: Color {
        switch viewModel.daemonStatus {
        case .enabled:
            return .green
        case .requiresApproval:
            return .orange
        case .notRegistered, .notFound:
            return .secondary
        @unknown default:
            return .secondary
        }
    }

    private func settingDetail(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
