import SwiftUI

/// The dropdown content rendered inside `MenuBarExtra`.
///
/// Reflects current mute state and allows the user to toggle each side.
/// Changes are forwarded to `AppViewModel`, which persists them and calls
/// `AudioPipeline.setSideMute` (ADR 0007, ADR 0010).
struct MenuBarView: View {

    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        // ── Status section ──────────────────────────────────────────
        // Consumer status row: ● Active / ○ Idle
        Text(viewModel.consumerActive ? "● Active" : "○ Idle — no app reading")
            .foregroundStyle(viewModel.consumerActive ? Color.primary : Color.secondary)
            .disabled(true)

        // Device name rows — shown grayed-out as display-only items.
        Text("Mic: \(viewModel.currentMicDeviceName.isEmpty ? "—" : viewModel.currentMicDeviceName)")
            .foregroundStyle(Color.secondary)
            .disabled(true)

        Text("System audio: \(viewModel.currentSystemAudioDeviceName.isEmpty ? "—" : viewModel.currentSystemAudioDeviceName)")
            .foregroundStyle(Color.secondary)
            .disabled(true)

        Divider()

        // ── Mute toggles ────────────────────────────────────────────
        // "Mic" toggle — checkmark when muted.
        Button {
            viewModel.micMuted.toggle()
        } label: {
            Label {
                Text("Mic")
            } icon: {
                if viewModel.micMuted {
                    Image(systemName: "checkmark")
                } else {
                    // Invisible spacer to keep alignment stable.
                    Image(systemName: "checkmark").hidden()
                }
            }
        }
        .keyboardShortcut(.none)

        // "System audio" toggle — checkmark when muted.
        Button {
            viewModel.systemAudioMuted.toggle()
        } label: {
            Label {
                Text("System audio")
            } icon: {
                if viewModel.systemAudioMuted {
                    Image(systemName: "checkmark")
                } else {
                    Image(systemName: "checkmark").hidden()
                }
            }
        }
        .keyboardShortcut(.none)

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
    }
}
