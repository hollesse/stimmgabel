import SwiftUI
import AudioEngine

/// Main SwiftUI app scene.
///
/// NOTE: This type does NOT use `@main` — the Xcode app target's `main.swift` is
/// the entry point, so it can call `StimmgabelApp.main()` explicitly. This avoids
/// the `@main` / `main.swift` conflict when the SPM module is embedded in an app target.
public struct StimmgabelApp: App {
    public init() {}

    public var body: some Scene {
        MenuBarExtra("Stimmgabel", systemImage: "mic.fill") {
            MenuBarView()
        }
    }
}
