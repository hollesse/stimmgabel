import SwiftUI

/// The dropdown content rendered inside `MenuBarExtra`.
///
/// Phase 2: shows consumer status, mic device name, and system audio device name.
struct MenuBarView: View {

    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        Text(viewModel.consumerActive ? "● Active" : "○ Idle — no app reading")
            .foregroundStyle(viewModel.consumerActive ? Color.primary : Color.secondary)
            .disabled(true)

        Text("Mic: \(viewModel.currentMicDeviceName.isEmpty ? "—" : viewModel.currentMicDeviceName)")
            .foregroundStyle(Color.secondary)
            .disabled(true)

        Text("System audio: \(viewModel.currentSystemAudioDeviceName.isEmpty ? "—" : viewModel.currentSystemAudioDeviceName)")
            .foregroundStyle(Color.secondary)
            .disabled(true)

        Divider()

        VStack(alignment: .leading, spacing: 2) {
            Text("System audio volume: \(Int(viewModel.sysAudioGain * 100))%")
                .foregroundStyle(Color.secondary)
                .font(.caption)
            Slider(value: $viewModel.sysAudioGain, in: 0...2, step: 0.1)
                .controlSize(.small)
                .frame(minWidth: 160)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
    }
}
