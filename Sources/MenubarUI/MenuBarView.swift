import SwiftUI

/// The dropdown content rendered inside `MenuBarExtra`.
///
/// Phase 1: shows consumer status and system audio device name only.
struct MenuBarView: View {

    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        Text(viewModel.consumerActive ? "● Active" : "○ Idle — no app reading")
            .foregroundStyle(viewModel.consumerActive ? Color.primary : Color.secondary)
            .disabled(true)

        Text("System audio: \(viewModel.currentSystemAudioDeviceName.isEmpty ? "—" : viewModel.currentSystemAudioDeviceName)")
            .foregroundStyle(Color.secondary)
            .disabled(true)

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
    }
}
