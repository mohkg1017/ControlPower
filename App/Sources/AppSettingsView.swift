import SwiftUI

struct AppSettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var settingsStore: SettingsStore

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { settingsStore.settings.launchAtLogin },
                    set: { value in
                        settingsStore.update { $0.launchAtLogin = value }
                        viewModel.applySettings()
                    }
                ))

                Toggle("Auto-register privileged helper on launch", isOn: Binding(
                    get: { settingsStore.settings.autoRegisterDaemonOnLaunch },
                    set: { value in
                        settingsStore.update { $0.autoRegisterDaemonOnLaunch = value }
                    }
                ))

                Stepper(value: Binding(
                    get: { settingsStore.settings.autoRefreshIntervalSeconds },
                    set: { value in
                        settingsStore.update { $0.autoRefreshIntervalSeconds = min(max(value, 10), 900) }
                        viewModel.applySettings()
                    }
                ), in: 10...900, step: 5) {
                    Text("Auto-refresh every \(settingsStore.settings.autoRefreshIntervalSeconds) seconds")
                }
            }

            Section("Safety") {
                Toggle("Prompt on quit when settings changed", isOn: Binding(
                    get: { settingsStore.settings.promptOnQuitIfChanged },
                    set: { value in
                        settingsStore.update { $0.promptOnQuitIfChanged = value }
                    }
                ))

                Toggle("Show thermal warning", isOn: Binding(
                    get: { settingsStore.settings.showThermalWarning },
                    set: { value in
                        settingsStore.update { $0.showThermalWarning = value }
                    }
                ))
            }

            Section("Helper") {
                LabeledContent("Status") {
                    Text(viewModel.daemonStatusText())
                }

                HStack {
                    Button("Register") {
                        viewModel.registerDaemonIfNeeded()
                    }
                    Button("Unregister") {
                        viewModel.unregisterDaemon()
                    }
                    Button("Open Login Items") {
                        viewModel.openLoginItemsSettings()
                    }
                }
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
}
