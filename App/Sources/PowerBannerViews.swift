import ServiceManagement
import SwiftUI

struct HelperApprovalBannerView: View {
    let compact: Bool
    let openSettings: () -> Void

    init(
        compact: Bool,
        openSettings: @escaping () -> Void = { SMAppService.openSystemSettingsLoginItems() }
    ) {
        self.compact = compact
        self.openSettings = openSettings
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            messageSection
            Spacer()
            Button(compact ? "Approve" : "Open Settings") {
                openSettings()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(compact ? .yellow : .accentColor)
        }
        .padding(compact ? 8 : 12)
        .background(Color.yellow.opacity(compact ? 0.05 : 0.1))
        .clipShape(RoundedRectangle(cornerRadius: compact ? 6 : 8))
    }

    @ViewBuilder
    private var messageSection: some View {
        if compact {
            Text("Helper not approved")
                .font(.caption2)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("Helper Not Approved")
                    .font(.caption.bold())
                Text("Approve in System Settings to enable sleep control.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct HelperRepairBannerView: View {
    let isBusy: Bool
    let compact: Bool
    let onRepair: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wrench.trianglebadge.exclamationmark")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            messageSection
            Spacer()
            Button("Repair") {
                onRepair()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.small)
            .disabled(isBusy)
        }
        .padding(compact ? 8 : 12)
        .background(Color.orange.opacity(compact ? 0.05 : 0.1))
        .clipShape(RoundedRectangle(cornerRadius: compact ? 6 : 8))
    }

    @ViewBuilder
    private var messageSection: some View {
        if compact {
            Text("Helper needs repair")
                .font(.caption2)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("Helper daemon needs repair")
                    .font(.caption.bold())
                Text("The background helper failed to start.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ErrorBannerView: View {
    let message: String
    let compact: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(message)
                .font(compact ? .caption2 : .caption)
                .lineLimit(compact ? 2 : nil)
            Spacer()
        }
        .padding(compact ? 8 : 12)
        .background(Color.red.opacity(compact ? 0.05 : 0.1))
        .clipShape(RoundedRectangle(cornerRadius: compact ? 6 : 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Error")
        .accessibilityValue(message)
        .accessibilityHint("Critical status message")
    }
}
