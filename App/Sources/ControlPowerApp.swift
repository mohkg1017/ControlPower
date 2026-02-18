import AppKit
import ControlPowerCore
import SwiftUI

@main
struct ControlPowerEntryPoint {
    static func main() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            ControlPowerTestHostApp.main()
        } else {
            ControlPowerApp.main()
        }
    }
}

private struct ControlPowerTestHostApp: App {
    var body: some Scene {
        WindowGroup("ControlPower") {
            EmptyView()
        }
    }
}

struct ControlPowerApp: App {
    @State private var viewModel = AppViewModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("ControlPower", id: "main") {
            MainView(viewModel: viewModel)
                .frame(minWidth: 700, minHeight: 460)
                .task {
                    viewModel.startup()
                }
        }
        .defaultSize(width: 750, height: 500)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("Power") {
                Button("Refresh Status") {
                    Task { await viewModel.refreshStatus() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(viewModel.isBusy)

                Button((viewModel.snapshot.disableSleep ?? false) ? "Disable Keep Awake" : "Enable Keep Awake") {
                    viewModel.toggleDisableSleep()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(viewModel.isBusy)

                Divider()

                Button("Restore Defaults") {
                    viewModel.restoreDefaults()
                }
                .disabled(viewModel.isBusy)
            }

            CommandGroup(after: .windowArrangement) {
                Button("Show ControlPower Window") {
                    openWindow(id: "main")
                }
                .keyboardShortcut("0", modifiers: .command)
            }

            CommandGroup(replacing: .appTermination) {
                Button("Quit ControlPower") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }

        MenuBarExtra("ControlPower", systemImage: "bolt.shield") {
            MenuBarPanelView(viewModel: viewModel) {
                NSApp.terminate(nil)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
