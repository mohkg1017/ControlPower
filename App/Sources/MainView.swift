import ControlPowerCore
import SwiftUI

struct MainView: View {
    @Bindable var viewModel: AppViewModel
    @SceneStorage("controlpower.selectedTab") private var selectedTabStorage: String = Tab.overview.rawValue

    enum Tab: String, Hashable {
        case overview
        case settings
        case advanced
        case about
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selectedTabBinding) {
                NavigationLink(value: Tab.overview) {
                    Label("Overview", systemImage: "bolt.shield")
                }
                NavigationLink(value: Tab.settings) {
                    Label("Settings", systemImage: "gear")
                }
                NavigationLink(value: Tab.advanced) {
                    Label("Raw Status", systemImage: "terminal")
                }
                NavigationLink(value: Tab.about) {
                    Label("About", systemImage: "info.circle")
                }
            }
            .navigationTitle("ControlPower")
        } detail: {
            ZStack {
                TahoeBackgroundView(showAnimatedMesh: selectedTab == .overview)

                switch selectedTab {
                case .overview:
                    OverviewTabView(viewModel: viewModel)
                case .settings:
                    ControlPowerSettingsView(viewModel: viewModel)
                        .scrollContentBackground(.hidden)
                        .navigationTitle("Settings")
                case .advanced:
                    AdvancedStatusTabView(viewModel: viewModel)
                case .about:
                    AboutTabView()
                }
            }
            .transition(.opacity)
        }
    }

    private var selectedTab: Tab {
        Tab(rawValue: selectedTabStorage) ?? .overview
    }

    private var selectedTabBinding: Binding<Tab?> {
        Binding(
            get: { selectedTab },
            set: { selectedTabStorage = ($0 ?? .overview).rawValue }
        )
    }
}

private struct OverviewTabView: View {
    @Bindable var viewModel: AppViewModel
    private let timerDurations = [30, 60, 120, 240]

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                statusHeader

                VStack(spacing: 16) {
                    mainActionButton
                    sleepDisplayButton

                    if viewModel.disableSleepDisplayValue {
                        timerControls
                    }

                    secondaryActions
                }
                .padding(.horizontal, 24)

                if viewModel.requiresHelperApproval {
                    HelperApprovalBannerView(compact: false)
                        .padding(.horizontal, 24)
                }

                if viewModel.helperNeedsRepair {
                    HelperRepairBannerView(isBusy: viewModel.isBusy, compact: false) {
                        Task { [weak viewModel] in
                            await viewModel?.repairDaemon()
                        }
                    }
                    .padding(.horizontal, 24)
                }

                if let error = viewModel.lastError {
                    ErrorBannerView(message: error, compact: false)
                        .padding(.horizontal, 24)
                }
            }
            .padding(.vertical, 24)
        }
        .navigationTitle("Overview")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await viewModel.refreshStatus() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isBusy)
            }
        }
    }

    private var statusHeader: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(viewModel.statusTint.color.opacity(0.1))
                    .frame(width: 80, height: 80)

                Image(systemName: viewModel.statusIconName)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(viewModel.statusTint.color)
                    .symbolEffect(.bounce, value: viewModel.powerMode)
                    .accessibilityHidden(true)
            }

            VStack(spacing: 4) {
                Text(viewModel.statusTitle)
                    .font(.title2.bold())

                if let timerEndDate = viewModel.activeTimerEndDate {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if let remainingTimeString = AppViewModel.remainingTimeString(until: timerEndDate, now: context.date) {
                            Text("Expires in \(remainingTimeString)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.orange)
                        } else {
                            Text(viewModel.statusDescription)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(viewModel.statusDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var timerControls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Stay Awake For...", systemImage: "timer")
                        .font(.subheadline.bold())
                    Spacer()
                    if viewModel.isTimerActive {
                        Button("Cancel Timer", role: .destructive) {
                            viewModel.cancelTimer()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .font(.caption.bold())
                    }
                }

                HStack(spacing: 8) {
                    ForEach(timerDurations, id: \.self) { minutes in
                        let isSelected = viewModel.selectedDurationMinutes == minutes && viewModel.isTimerActive
                        Button {
                            viewModel.startTimer(minutes: minutes)
                        } label: {
                            HStack(spacing: 6) {
                                if isSelected {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                                Text(AppViewModel.durationLabel(for: minutes))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(isSelected ? .orange : .secondary)
                        .accessibilityValue(isSelected ? "Selected" : "Not selected")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
            .padding(4)
        }
    }

    private var mainActionButton: some View {
        Button {
            viewModel.toggleDisableSleep()
        } label: {
            HStack {
                Image(systemName: viewModel.disableSleepDisplayValue ? "moon.zzz.fill" : "sun.max.fill")
                Text(viewModel.disableSleepDisplayValue ? "Allow System Sleep" : "Prevent System Sleep")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(viewModel.disableSleepDisplayValue ? .orange : .accentColor)
        .controlSize(.large)
        .disabled(viewModel.isBusy)
    }

    private var sleepDisplayButton: some View {
        Button {
            viewModel.sleepDisplay()
        } label: {
            HStack {
                Image(systemName: "display")
                Text("Sleep Display Now")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(viewModel.isBusy)
    }

    private var secondaryActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostics")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            GroupBox {
                VStack(spacing: 0) {
                    HStack {
                        Label("Battery Level", systemImage: "battery.100")
                        Spacer()
                        Text("\(viewModel.batteryLevel)%")
                            .foregroundStyle(viewModel.batteryLevel <= 20 ? .red : .secondary)
                    }
                    .padding(.vertical, 8)

                    Divider()

                    HStack {
                        Label("Helper Status", systemImage: helperStatusIconName)
                            .foregroundStyle(helperStatusColor)
                        Spacer()
                        Text(viewModel.helperStatusText)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private var helperStatusIconName: String {
        switch viewModel.helperStatus {
        case .enabled:
            return "checkmark.shield.fill"
        case .requiresApproval:
            return "exclamationmark.shield.fill"
        case .disabled:
            return "xmark.shield.fill"
        }
    }

    private var helperStatusColor: Color {
        switch viewModel.helperStatus {
        case .enabled:
            return .green
        case .requiresApproval:
            return .yellow
        case .disabled:
            return .secondary
        }
    }
}

private struct AdvancedStatusTabView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                advancedHeader
                advancedTerminalBox
                GroupBox("Key Parameter Descriptions") {
                    VStack(alignment: .leading, spacing: 12) {
                        parameterDescription(key: "SleepDisabled", description: "If 1, system-wide sleep is inhibited.")
                        parameterDescription(key: "lidwake", description: "Wake the machine when the lid is opened.")
                        parameterDescription(key: "standby", description: "Machine will go into standby mode.")
                        parameterDescription(key: "powernap", description: "Periodic wake for background tasks.")
                    }
                    .padding(8)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("Raw Status")
    }

    private var advancedHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("System Power Configuration")
                    .font(.headline)
                Text("Currently active pmset -g settings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                viewModel.copyRawOutputToPasteboard()
            } label: {
                Label("Copy Output", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
    }

    private var advancedTerminalBox: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Power Settings")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("pmset -g")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            Text(viewModel.snapshot.summary.isEmpty ? "No pmset output yet" : viewModel.snapshot.summary)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .padding(.horizontal, 24)
    }

    private func parameterDescription(key: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.bold)
                .frame(width: 110, alignment: .leading)
                .foregroundStyle(Color.accentColor)

            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AboutTabView: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .shadow(radius: 10)

            VStack(spacing: 8) {
                Text("ControlPower")
                    .font(.largeTitle.bold())

                Text(AppViewModel.appVersion)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()
                .frame(maxWidth: 200)

            VStack(spacing: 4) {
                Text("Made By Moe")
                    .font(.headline)

                if let profileURL = URL(string: "https://x.com/mohkg1017") {
                    Link("@mohkg1017", destination: profileURL)
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.top, 10)

            Spacer()

            Text("© 2026 Moe. All rights reserved.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("About")
    }
}

private struct TahoeBackgroundView: View {
    let showAnimatedMesh: Bool

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if showAnimatedMesh {
                AnimatedTahoeBackground()
            }
        }
    }
}

extension PowerStatusTint {
    var color: Color {
        switch self {
        case .noSleep: return .orange
        case .normal: return .green
        case .unknown: return .secondary
        }
    }
}

private struct AnimatedTahoeBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

    var body: some View {
        Group {
            if reduceMotion || isLowPowerModeEnabled || scenePhase != .active || controlActiveState != .key {
                StaticMeshLayer()
                    .allowsHitTesting(false)
            } else {
                TimelineView(.periodic(from: .now, by: 5.0)) { context in
                    AnimatedMeshLayer(phase: context.date.timeIntervalSinceReferenceDate)
                }
                .allowsHitTesting(false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }
}

private struct AnimatedMeshLayer: View {
    let phase: TimeInterval
    private static let colors: [Color] = [
        .accentColor.opacity(0.1), .accentColor.opacity(0.05), .purple.opacity(0.1),
        .blue.opacity(0.05), .accentColor.opacity(0.15), .blue.opacity(0.1),
        .purple.opacity(0.05), .blue.opacity(0.05), .accentColor.opacity(0.1)
    ]

    var body: some View {
        let x = Float(0.5 + (sin(phase * 0.35) * 0.18))
        let y = Float(0.5 + (cos(phase * 0.3) * 0.18))
        MeshGradient(width: 3, height: 3, points: [
            .init(0, 0), .init(0.5, 0), .init(1, 0),
            .init(0, 0.5), .init(x, y), .init(1, 0.5),
            .init(0, 1), .init(0.5, 1), .init(1, 1)
        ], colors: Self.colors)
        .ignoresSafeArea()
        .blur(radius: 8)
    }
}

private struct StaticMeshLayer: View {
    private static let points: [SIMD2<Float>] = [
        .init(0, 0), .init(0.5, 0), .init(1, 0),
        .init(0, 0.5), .init(0.5, 0.5), .init(1, 0.5),
        .init(0, 1), .init(0.5, 1), .init(1, 1)
    ]
    private static let colors: [Color] = [
        .accentColor.opacity(0.1), .accentColor.opacity(0.05), .purple.opacity(0.1),
        .blue.opacity(0.05), .accentColor.opacity(0.15), .blue.opacity(0.1),
        .purple.opacity(0.05), .blue.opacity(0.05), .accentColor.opacity(0.1)
    ]

    var body: some View {
        MeshGradient(width: 3, height: 3, points: Self.points, colors: Self.colors)
            .ignoresSafeArea()
            .blur(radius: 8)
    }
}
