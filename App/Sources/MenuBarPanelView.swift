import ControlPowerCore
import SwiftUI

struct MenuBarPanelView: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.openWindow) private var openWindow
    let quit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            statusAndActions
                .padding(16)

            Divider()

            footer
        }
        .frame(width: 300)
    }

    private var header: some View {
        HStack {
            Label("ControlPower", systemImage: "bolt.shield")
                .font(.headline)
                .foregroundStyle(Color.accentColor)

            Spacer()

            Button {
                Task { await viewModel.refreshStatus() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .imageScale(.small)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isBusy)
            .symbolEffect(.bounce, value: viewModel.isBusy)
            .accessibilityLabel("Refresh Status")
            .accessibilityHint("Refreshes current power status")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var statusAndActions: some View {
        VStack(spacing: 16) {
            powerStatusRow

            if let timerEndDate = viewModel.activeTimerEndDate {
                timerRow(endDate: timerEndDate)
            }

            sleepDisplayRow

            if viewModel.requiresHelperApproval {
                HelperApprovalBannerView(compact: true)
            }

            if viewModel.helperNeedsRepair {
                HelperRepairBannerView(isBusy: viewModel.isBusy, compact: true) {
                    Task { [weak viewModel] in
                        await viewModel?.repairDaemon()
                    }
                }
            }

            if let error = viewModel.lastError {
                ErrorBannerView(message: error, compact: true)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 20) {
            Button("Open Window") {
                openWindow(id: "main")
            }
            .buttonStyle(.plain)
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Spacer()

            Button("Quit") {
                quit()
            }
            .buttonStyle(.plain)
            .font(.subheadline)
            .foregroundStyle(.red.opacity(0.8))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Helpers

    private var powerStatusRow: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(viewModel.statusTint.color.opacity(0.1))
                    .frame(width: 44, height: 44)

                Image(systemName: viewModel.statusIconName)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(viewModel.statusTint.color)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.statusTitle)
                    .font(.system(.body, weight: .semibold))
                Text(viewModel.sourceText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("Prevent System Sleep", isOn: disableSleepBinding)
                .labelsHidden()
                .accessibilityLabel("Prevent System Sleep")
                .toggleStyle(.switch)
                .disabled(viewModel.isBusy)
        }
    }

    private var sleepDisplayRow: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 44, height: 44)

                Image(systemName: "display")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Sleep Display")
                    .font(.system(.body, weight: .semibold))
                Text("Turn off screen instantly")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                viewModel.sleepDisplay()
            } label: {
                Text("Sleep Now")
                    .font(.caption.bold())
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
            .controlSize(.small)
            .disabled(viewModel.isBusy)
        }
    }

    private func timerRow(endDate: Date) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.1))
                    .frame(width: 44, height: 44)

                Image(systemName: "timer")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.orange)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Keep Awake Timer")
                    .font(.system(.body, weight: .semibold))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let remaining = AppViewModel.remainingTimeString(until: endDate, now: context.date) {
                        Text(remaining)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.orange)
                    } else {
                        Text("Expiring…")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Button {
                viewModel.cancelTimer()
            } label: {
                Text("Cancel")
                    .font(.caption.bold())
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .controlSize(.small)
        }
    }

    private var disableSleepBinding: Binding<Bool> {
        Binding(
            get: { viewModel.disableSleepDisplayValue },
            set: { viewModel.setDisableSleepEnabled($0) }
        )
    }
}
