import SwiftUI

struct MenuBarPanelView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ControlPower")
                .font(.headline)

            Text("SleepDisabled: \(boolText(viewModel.snapshot.disableSleep))")
                .font(.system(.caption, design: .monospaced))
            Text("lidwake: \(boolText(viewModel.snapshot.lidWake))")
                .font(.system(.caption, design: .monospaced))

            Divider()

            Button((viewModel.snapshot.disableSleep ?? false) ? "Disable Keep Awake" : "Enable Keep Awake") {
                viewModel.toggleDisableSleep()
            }
            .disabled(viewModel.isBusy)

            Button((viewModel.snapshot.lidWake ?? true) ? "Disable Lid Wake" : "Enable Lid Wake") {
                viewModel.toggleLidWake()
            }
            .disabled(viewModel.isBusy)

            Menu("Apply Preset") {
                ForEach(PowerPreset.allCases) { preset in
                    Button(preset.title) {
                        viewModel.applyPreset(preset)
                    }
                }
            }

            Divider()

            Button("Refresh Status") {
                Task { await viewModel.refreshStatus() }
            }
            Button("Open Control Window") {
                openWindow(id: "main")
            }
            Button("Open Settings") {
                openSettings()
            }
            Button("Open Login Items Settings") {
                viewModel.openLoginItemsSettings()
            }

            Divider()

            Button("Quit") {
                viewModel.requestQuit()
            }
        }
        .padding(12)
    }

    private func boolText(_ value: Bool?) -> String {
        guard let value else { return "unknown" }
        return value ? "1" : "0"
    }
}
