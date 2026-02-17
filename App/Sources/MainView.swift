import SwiftUI

struct MainView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var settingsStore: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ControlPower")
                        .font(.title2.weight(.semibold))
                    Text("Manage sleep behavior from the menu bar using a privileged helper.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") {
                    Task { await viewModel.refreshStatus() }
                }
                .disabled(viewModel.isBusy)
            }

            if settingsStore.settings.showThermalWarning {
                Text("These settings apply system-wide. Monitor device heat during long sessions.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            GroupBox("Current Status") {
                VStack(alignment: .leading, spacing: 8) {
                    statusRow(title: "SleepDisabled", value: boolText(viewModel.snapshot.disableSleep))
                    statusRow(title: "lidwake", value: boolText(viewModel.snapshot.lidWake))
                    Text(viewModel.snapshot.summary.isEmpty ? "No status output yet" : viewModel.snapshot.summary)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
                Button((viewModel.snapshot.disableSleep ?? false) ? "Disable Keep Awake" : "Enable Keep Awake") {
                    viewModel.toggleDisableSleep()
                }
                .disabled(viewModel.isBusy)

                Button((viewModel.snapshot.lidWake ?? true) ? "Disable Lid Wake" : "Enable Lid Wake") {
                    viewModel.toggleLidWake()
                }
                .disabled(viewModel.isBusy)

                Button("Restore Defaults") {
                    viewModel.restoreDefaults()
                }
                .disabled(viewModel.isBusy)
            }

            GroupBox("Presets") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(PowerPreset.allCases) { preset in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.title)
                                    .font(.body.weight(.medium))
                                Text(preset.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Apply") {
                                viewModel.applyPreset(preset)
                            }
                            .disabled(viewModel.isBusy)
                        }
                    }
                }
            }

            GroupBox("Helper") {
                HStack {
                    Text("Status: \(viewModel.daemonStatusText())")
                    Spacer()
                    Button("Register") {
                        viewModel.registerDaemonIfNeeded()
                    }
                    Button("Unregister") {
                        viewModel.unregisterDaemon()
                    }
                    Button("Settings") {
                        viewModel.openLoginItemsSettings()
                    }
                }
            }

            if let error = viewModel.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            GroupBox("Activity") {
                List(viewModel.logEntries) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(entry.date.formatted(date: .omitted, time: .standard))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(entry.message)
                            .font(.callout)
                    }
                }
                .frame(minHeight: 140)
            }
        }
        .padding(16)
    }

    private func statusRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(.body, design: .monospaced))
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced).weight(.medium))
        }
    }

    private func boolText(_ value: Bool?) -> String {
        guard let value else { return "unknown" }
        return value ? "1" : "0"
    }
}
