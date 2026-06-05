import SwiftUI

struct MenuBarView: View {
    var body: some View {
        VStack {
            Text("Stimmgabel — running")
                .padding(.horizontal)
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.vertical, 4)
    }
}
