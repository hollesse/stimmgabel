import SwiftUI

/// The dropdown content rendered inside `MenuBarExtra`.
///
/// Reflects current mute state and allows the user to toggle each side.
/// Changes are forwarded to `AppViewModel`, which persists them and calls
/// `AudioPipeline.setSideMute` (ADR 0007, ADR 0010).
struct MenuBarView: View {

    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
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
