import SwiftUI
import ServiceManagement

struct MainView: View {
    let viewModel: AppViewModel
    @ObservedObject var settingsStore: SettingsStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                MainHeaderView(viewModel: viewModel)

                Text("Manage sleep behavior from the menu bar using a privileged helper.")
                    .foregroundStyle(.secondary)

                if settingsStore.settings.showThermalWarning {
                    Label("These settings apply system-wide. Monitor device heat during long sessions.", systemImage: "thermometer.sun")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                CurrentStatusSection(viewModel: viewModel)
                QuickActionsSection(viewModel: viewModel)
                PresetsSection(viewModel: viewModel)
                HelperSection(viewModel: viewModel, openSettings: openSettings)
                TerminalCommandsSection(viewModel: viewModel)

                if let error = viewModel.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                ActivitySection(entries: viewModel.logEntries)
            }
            .padding(16)
        }
    }
}

private struct MainHeaderView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Label("ControlPower", systemImage: "bolt.shield")
                .font(.title2.weight(.semibold))
            Spacer()
            Text(viewModel.daemonStatusText())
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(statusTint(for: viewModel.daemonStatus).opacity(0.16))
                .foregroundStyle(statusTint(for: viewModel.daemonStatus))
                .clipShape(Capsule())
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await viewModel.refreshStatus() }
            }
            .disabled(viewModel.isBusy)
        }
    }
}

private struct CurrentStatusSection: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                statusRow(title: "Keep Awake Override", value: boolText(viewModel.snapshot.disableSleep))
                statusRow(title: "Wake on Lid Open", value: boolText(viewModel.snapshot.lidWake))
                statusRow(title: "Source", value: viewModel.statusSourceText())
                Text(viewModel.snapshot.summary.isEmpty ? "No status output yet" : viewModel.snapshot.summary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Current Status", systemImage: "gauge.with.dots.needle.33percent")
        }
    }
}

private struct QuickActionsSection: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ControlGroup {
                        Button((viewModel.snapshot.disableSleep ?? false) ? "Disable Keep Awake" : "Enable Keep Awake", systemImage: "moon.zzz.fill") {
                            viewModel.toggleDisableSleep()
                        }
                        Button((viewModel.snapshot.lidWake ?? true) ? "Disable Lid Wake" : "Enable Lid Wake", systemImage: "laptopcomputer") {
                            viewModel.toggleLidWake()
                        }
                    }
                    .disabled(viewModel.isBusy || !viewModel.helperReadyForCommands)

                    Menu("Timed Keep Awake", systemImage: "timer") {
                        Button("30 minutes") {
                            viewModel.startTimedKeepAwake(minutes: 30)
                        }
                        Button("1 hour") {
                            viewModel.startTimedKeepAwake(minutes: 60)
                        }
                        Button("2 hours") {
                            viewModel.startTimedKeepAwake(minutes: 120)
                        }
                        Divider()
                        Button("Cancel Timed Session", role: .destructive) {
                            viewModel.cancelTimedKeepAwake()
                        }
                        .disabled(viewModel.timedKeepAwakeEndDate == nil)
                    }
                    .disabled(viewModel.isBusy || !viewModel.helperReadyForCommands)

                    Spacer()

                    Button("Restore Defaults", systemImage: "arrow.uturn.backward.circle", role: .destructive) {
                        viewModel.restoreDefaults()
                    }
                    .disabled(viewModel.isBusy || !viewModel.helperReadyForCommands)
                }

                HStack(spacing: 12) {
                    Stepper(value: Binding(
                        get: { viewModel.customTimedKeepAwakeMinutes },
                        set: { viewModel.setCustomTimedKeepAwakeMinutes($0) }
                    ), in: 5...720, step: 5) {
                        Text("Custom timer: \(viewModel.customTimedKeepAwakeMinutes) minutes")
                    }
                    .disabled(viewModel.isBusy || !viewModel.helperReadyForCommands)

                    Button("Start Custom Timer", systemImage: "hourglass.badge.plus") {
                        viewModel.startCustomTimedKeepAwake()
                    }
                    .disabled(viewModel.isBusy || !viewModel.helperReadyForCommands)
                }

                if let endDate = viewModel.timedKeepAwakeEndDate {
                    Label("Timed keep awake ends at \(endDate.formatted(date: .omitted, time: .shortened))", systemImage: "timer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            Label("Quick Actions", systemImage: "switch.2")
        }
    }
}

private struct PresetsSection: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("Saved Preset", selection: Binding(
                        get: { viewModel.selectedPreset },
                        set: { viewModel.setSelectedPreset($0) }
                    )) {
                        ForEach(PowerPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)

                    Spacer()

                    Button("Apply Saved Preset", systemImage: "play.fill") {
                        viewModel.applySelectedPreset()
                    }
                    .disabled(viewModel.isBusy || !viewModel.helperReadyForCommands)
                }

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
                        Button("Apply", systemImage: "play.fill") {
                            viewModel.applyPreset(preset)
                        }
                        .disabled(viewModel.isBusy || !viewModel.helperReadyForCommands)
                    }
                }
            }
        } label: {
            Label("Presets", systemImage: "slider.horizontal.3")
        }
    }
}

private struct HelperSection: View {
    @ObservedObject var viewModel: AppViewModel
    let openSettings: OpenSettingsAction

    var body: some View {
        GroupBox {
            HStack {
                Label("Status: \(viewModel.daemonStatusText())", systemImage: statusSymbol(for: viewModel.daemonStatus))
                    .foregroundStyle(statusTint(for: viewModel.daemonStatus))
                Spacer()
                ControlGroup {
                    Button("Register", systemImage: "plus.circle") {
                        viewModel.registerDaemonIfNeeded()
                    }
                    .disabled(viewModel.daemonStatus == .enabled || viewModel.daemonStatus == .requiresApproval)
                    Button("Unregister", systemImage: "minus.circle") {
                        viewModel.unregisterDaemon()
                    }
                    .disabled(viewModel.daemonStatus == .notRegistered || viewModel.daemonStatus == .notFound)
                    Button("Open App Settings", systemImage: "gearshape") {
                        openSettings()
                    }
                    Button("Open Login Items", systemImage: "person.crop.circle.badge.checkmark") {
                        viewModel.openLoginItemsSettings()
                    }
                }
            }

            if viewModel.helperNeedsApproval {
                Text("Helper registration is pending approval in System Settings > Login Items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } label: {
            Label("Privileged Helper", systemImage: "lock.shield")
        }
    }
}

private struct TerminalCommandsSection: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(viewModel.terminalCommands) { item in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(.body.weight(.medium))
                            Text(item.command)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Copy", systemImage: "doc.on.doc") {
                            viewModel.copyTerminalCommand(item)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        } label: {
            Label("Terminal Commands", systemImage: "terminal")
        }
    }
}

private struct ActivitySection: View {
    let entries: [LogEntry]

    var body: some View {
        GroupBox {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(entries) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(entry.date.formatted(date: .omitted, time: .standard))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(entry.message)
                                .font(.callout)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(minHeight: 140, maxHeight: 240)
        } label: {
            Label("Activity", systemImage: "clock.arrow.circlepath")
        }
    }
}

private func boolText(_ value: Bool?) -> String {
    guard let value else { return "Unknown" }
    return value ? "Enabled" : "Disabled"
}

private func statusRow(title: String, value: String) -> some View {
    LabeledContent {
        Text(value)
            .font(.body.weight(.medium))
    } label: {
        Text(title)
            .font(.body)
    }
}

private func statusSymbol(for status: SMAppService.Status) -> String {
    switch status {
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

private func statusTint(for status: SMAppService.Status) -> Color {
    switch status {
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
