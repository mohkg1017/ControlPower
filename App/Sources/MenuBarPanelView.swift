import SwiftUI

struct MenuBarPanelView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("ControlPower", systemImage: "bolt.shield")
                .font(.headline)

            LabeledContent("Keep Awake Override") {
                Text(boolText(viewModel.snapshot.disableSleep))
                    .font(.system(.caption, design: .monospaced).weight(.medium))
            }
            LabeledContent("Wake on Lid Open") {
                Text(boolText(viewModel.snapshot.lidWake))
                    .font(.system(.caption, design: .monospaced).weight(.medium))
            }
            LabeledContent("Preset") {
                Text(viewModel.selectedPreset.title)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
            }
            LabeledContent("Helper") {
                Label(viewModel.daemonStatusText(), systemImage: helperStatusSymbol)
                    .font(.caption)
                    .foregroundStyle(helperStatusTint)
            }

            Divider()

            ControlGroup {
                Button("Apply Saved Preset", systemImage: "play.fill") {
                    viewModel.applySelectedPreset()
                }
                Button((viewModel.snapshot.disableSleep ?? false) ? "Disable Keep Awake" : "Enable Keep Awake", systemImage: "moon.zzz.fill") {
                    viewModel.toggleDisableSleep()
                }
                Button((viewModel.snapshot.lidWake ?? true) ? "Disable Lid Wake" : "Enable Lid Wake", systemImage: "laptopcomputer") {
                    viewModel.toggleLidWake()
                }
                Button("Restore Defaults", systemImage: "arrow.uturn.backward.circle", role: .destructive) {
                    viewModel.restoreDefaults()
                }
            }
            .disabled(viewModel.isBusy || !viewModel.helperReadyForCommands)

            Menu("Apply Preset", systemImage: "slider.horizontal.3") {
                ForEach(PowerPreset.allCases) { preset in
                    Button(preset.title) {
                        viewModel.applyPreset(preset)
                    }
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

            HStack(spacing: 8) {
                Stepper(value: Binding(
                    get: { viewModel.customTimedKeepAwakeMinutes },
                    set: { viewModel.setCustomTimedKeepAwakeMinutes($0) }
                ), in: 5...720, step: 5) {
                    Text("Custom: \(viewModel.customTimedKeepAwakeMinutes)m")
                        .font(.caption)
                }
                Button("Start", systemImage: "hourglass.badge.plus") {
                    viewModel.startCustomTimedKeepAwake()
                }
            }
            .disabled(viewModel.isBusy || !viewModel.helperReadyForCommands)

            if let endDate = viewModel.timedKeepAwakeEndDate {
                Label("Timed keep awake ends at \(endDate.formatted(date: .omitted, time: .shortened))", systemImage: "timer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Menu("Copy Terminal Command", systemImage: "terminal") {
                ForEach(viewModel.terminalCommands) { item in
                    Button(item.title) {
                        viewModel.copyTerminalCommand(item)
                    }
                }
            }

            Divider()

            Button("Refresh Status", systemImage: "arrow.clockwise") {
                Task { await viewModel.refreshStatus() }
            }
            .disabled(viewModel.isBusy)
            Button("Open Control Window", systemImage: "macwindow") {
                openWindow(id: "main")
            }
            Button("Open Settings", systemImage: "gearshape") {
                openSettings()
            }
            Button("Open Login Items Settings", systemImage: "person.crop.circle.badge.checkmark") {
                viewModel.openLoginItemsSettings()
            }

            if viewModel.helperNeedsApproval {
                Label("Helper needs approval", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("Quit", systemImage: "xmark.circle") {
                viewModel.requestQuit()
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(12)
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

    private func boolText(_ value: Bool?) -> String {
        guard let value else { return "Unknown" }
        return value ? "Enabled" : "Disabled"
    }
}
