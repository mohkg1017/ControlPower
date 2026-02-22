import ControlPowerCore
import ServiceManagement
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
                tahoeBackground

                switch selectedTab {
                case .overview:
                    overviewView
                case .settings:
                    settingsView
                case .advanced:
                    advancedView
                case .about:
                    aboutView
                }
            }
            .transition(.opacity)
        }
    }

    private var aboutView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .shadow(radius: 10)
            
            VStack(spacing: 8) {
                Text("ControlPower")
                    .font(.largeTitle.bold())
                
                Text(appVersionText)
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

    private var overviewView: some View {
        ScrollView {
            VStack(spacing: 24) {
                statusHeader

                VStack(spacing: 16) {
                    mainActionButton
                    sleepDisplayButton

                    if viewModel.snapshot.disableSleep == true {
                        timerControls
                    }

                    secondaryActions
                }
                .padding(.horizontal, 24)

                if !viewModel.isHelperEnabled {
                    helperApprovalBanner
                        .padding(.horizontal, 24)
                }

                if viewModel.helperNeedsRepair {
                    helperRepairBanner
                        .padding(.horizontal, 24)
                }

                if let error = viewModel.lastError {
                    errorBanner(error)
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

    private var settingsView: some View {
        Form {
            Section {
                Toggle("Low Battery Protection", isOn: $viewModel.isLowBatteryProtectionEnabled)
                Text("Automatically turn off 'No Sleep' when battery is 20% or lower.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Power Safety")
            }

            Section {
                Toggle("Launch Background Helper at Login", isOn: helperEnabledBinding)
            } header: {
                Text("Automation")
            } footer: {
                Text("The background helper is required for 'No Sleep' to function across reboots.")
            }
            
            Section {
                Button("Restore System Defaults") {
                    viewModel.restoreDefaults()
                }
                .disabled(viewModel.isBusy)
            } header: {
                Text("Maintenance")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("Settings")
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
            }

            VStack(spacing: 4) {
                Text(viewModel.statusTitle)
                    .font(.title2.bold())

                if let remainingTimeString = viewModel.remainingTimeString {
                    Text("Expires in \(remainingTimeString)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.orange)
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
                    if viewModel.remainingSeconds != nil {
                        Button("Cancel Timer", role: .destructive) {
                            viewModel.cancelTimer()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .font(.caption.bold())
                    }
                }
                
                HStack(spacing: 8) {
                    ForEach([30, 60, 120, 240], id: \.self) { mins in
                        Button {
                            viewModel.startTimer(minutes: mins)
                        } label: {
                            Text(AppViewModel.durationLabel(for: mins))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(viewModel.selectedDurationMinutes == mins && viewModel.remainingSeconds != nil ? .orange : .secondary)
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
                Image(systemName: (viewModel.snapshot.disableSleep ?? false) ? "moon.zzz.fill" : "sun.max.fill")
                Text((viewModel.snapshot.disableSleep ?? false) ? "Allow System Sleep" : "Prevent System Sleep")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(viewModel.snapshot.disableSleep == true ? .orange : .accentColor)
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
                        Label("Helper Status", systemImage: viewModel.isHelperEnabled ? "checkmark.shield.fill" : "xmark.shield.fill")
                            .foregroundStyle(viewModel.isHelperEnabled ? .green : .red)
                        Spacer()
                        Text(viewModel.isHelperEnabled ? "Active" : "Inactive")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private var advancedView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                advancedHeader
                advancedTerminalBox
                GroupBox("Key Parameter Descriptions") {
                    VStack(alignment: .leading, spacing: 12) {
                        parameterDesc(key: "SleepDisabled", desc: "If 1, system-wide sleep is inhibited.")
                        parameterDesc(key: "lidwake", desc: "Wake the machine when the lid is opened.")
                        parameterDesc(key: "standby", desc: "Machine will go into standby mode.")
                        parameterDesc(key: "powernap", desc: "Periodic wake for background tasks.")
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
                viewModel.copyStatusToClipboard()
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
                Circle().fill(.red.opacity(0.6)).frame(width: 10, height: 10)
                Circle().fill(.orange.opacity(0.6)).frame(width: 10, height: 10)
                Circle().fill(.green.opacity(0.6)).frame(width: 10, height: 10)
                Spacer()
                Text("pmset -g")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.05))

            Divider()

            Text(viewModel.snapshot.summary.isEmpty ? "No pmset output yet" : viewModel.snapshot.summary)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .padding(.horizontal, 24)
    }

    private func parameterDesc(key: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.bold)
                .frame(width: 110, alignment: .leading)
                .foregroundStyle(Color.accentColor)
            
            Text(desc)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var tahoeBackground: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if selectedTab == .overview {
                AnimatedTahoeBackground()
            }
        }
    }

    private var helperApprovalBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Helper Not Approved")
                    .font(.caption.bold())
                Text("Approve in System Settings to enable sleep control.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") {
                SMAppService.openSystemSettingsLoginItems()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.yellow.opacity(0.1))
        .cornerRadius(8)
    }

    private var helperRepairBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "wrench.trianglebadge.exclamationmark")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Helper daemon needs repair")
                    .font(.caption.bold())
                Text("The background helper failed to start.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Repair") {
                Task { await viewModel.repairDaemon() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.small)
            .disabled(viewModel.isBusy)
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
            Spacer()
        }
        .padding(12)
        .background(Color.red.opacity(0.1))
        .cornerRadius(8)
    }

    // MARK: - Helpers

    private var helperEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isHelperEnabled },
            set: { viewModel.setHelperEnabled($0) }
        )
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

    private var appVersionText: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Version \(shortVersion) (Build \(buildNumber))"
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

    var body: some View {
        if reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled || scenePhase != .active || controlActiveState != .key {
            StaticMeshLayer()
                .allowsHitTesting(false)
        } else {
            TimelineView(.periodic(from: .now, by: 3.0)) { context in
                AnimatedMeshLayer(phase: context.date.timeIntervalSinceReferenceDate)
            }
            .allowsHitTesting(false)
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
        .blur(radius: 16)
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
        .blur(radius: 14)
    }
}
