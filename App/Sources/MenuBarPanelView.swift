import ControlPowerCore
import ServiceManagement
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
        .background(Color(nsColor: .windowBackgroundColor))
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
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isBusy)
            .symbolEffect(.rotate, value: viewModel.isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var statusAndActions: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(viewModel.statusTint.color.opacity(0.1))
                        .frame(width: 44, height: 44)

                    Image(systemName: viewModel.statusIconName)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(viewModel.statusTint.color)
                }

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

            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(.purple.opacity(0.1))
                        .frame(width: 44, height: 44)

                    Image(systemName: "display")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.purple)
                }

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
                    Image(systemName: "power.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.purple)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isBusy)
            }

            if !viewModel.isHelperEnabled {
                HStack {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.yellow)
                    Text("Helper not approved")
                        .font(.caption2)
                    Spacer()
                    Button("Approve") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.yellow)
                }
                .padding(8)
                .background(Color.yellow.opacity(0.05))
                .cornerRadius(6)
            }

            if viewModel.helperNeedsRepair {
                HStack {
                    Image(systemName: "wrench.trianglebadge.exclamationmark")
                        .foregroundStyle(.orange)
                    Text("Helper needs repair")
                        .font(.caption2)
                    Spacer()
                    Button("Repair") {
                        Task { await viewModel.repairDaemon() }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(viewModel.isBusy)
                }
                .padding(8)
                .background(Color.orange.opacity(0.05))
                .cornerRadius(6)
            }

            if let error = viewModel.lastError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption2)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(8)
                .background(Color.red.opacity(0.05))
                .cornerRadius(6)
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
        .background(Color.black.opacity(0.03))
    }

    // MARK: - Helpers

    private var disableSleepBinding: Binding<Bool> {
        Binding(
            get: { viewModel.snapshot.disableSleep ?? false },
            set: { _ in viewModel.toggleDisableSleep() }
        )
    }
}
