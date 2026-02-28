import ControlPowerCore
import SwiftUI

struct ControlPowerSettingsView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
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
                    .disabled(viewModel.isBusy)
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
    }

    private var helperEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isHelperEnabled },
            set: { viewModel.setHelperEnabled($0) }
        )
    }
}
