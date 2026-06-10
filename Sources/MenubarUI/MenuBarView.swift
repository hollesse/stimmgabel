import SwiftUI

/// The dropdown content rendered inside `MenuBarExtra`.
///
/// Phase 2: shows consumer status, mic device name, and system audio device name.
struct MenuBarView: View {

    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status section
            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.consumerActive ? "● Active" : "○ Idle — no app reading")
                    .foregroundStyle(viewModel.consumerActive ? Color.primary : Color.secondary)
                Text("Mic: \(viewModel.currentMicDeviceName.isEmpty ? "—" : viewModel.currentMicDeviceName)")
                    .foregroundStyle(Color.secondary)
                    .font(.caption)
                Text("System audio: \(viewModel.currentSystemAudioDeviceName.isEmpty ? "—" : viewModel.currentSystemAudioDeviceName)")
                    .foregroundStyle(Color.secondary)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Gain section
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Sys audio volume")
                        .foregroundStyle(Color.secondary)
                        .font(.caption)
                    Spacer()
                    Text("\(Int(viewModel.sysAudioGain * 100))%")
                        .foregroundStyle(Color.secondary)
                        .font(.caption)
                        .monospacedDigit()
                }
                Slider(value: $viewModel.sysAudioGain, in: 0...2, step: 0.1)

                HStack {
                    Text("Mic volume")
                        .foregroundStyle(Color.secondary)
                        .font(.caption)
                    Spacer()
                    Text("\(Int(viewModel.micGain / 3.0 * 100))%")
                        .foregroundStyle(Color.secondary)
                        .font(.caption)
                        .monospacedDigit()
                }
                Slider(value: $viewModel.micGain, in: 0...6, step: 0.3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Quit
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .frame(width: 240)
    }
}
