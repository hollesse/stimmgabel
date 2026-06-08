import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        Text(viewModel.consumerActive ? "● Active" : "○ Idle — no app reading")
            .foregroundStyle(viewModel.consumerActive ? Color.primary : Color.secondary)
            .disabled(true)

        Text("Audio: \(viewModel.currentSystemAudioDeviceName.isEmpty ? "—" : viewModel.currentSystemAudioDeviceName)")
            .foregroundStyle(Color.secondary)
            .disabled(true)

        Divider()

        Button("Quit") { NSApplication.shared.terminate(nil) }
    }
}
