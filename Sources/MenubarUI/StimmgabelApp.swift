import SwiftUI
import AudioEngine
import AVFAudio

private final class SilentAdapter: UpstreamCaptureAdapter, @unchecked Sendable {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var isRunning = false
    var deviceName: String { "" }
    func start() {}
    func stop() { isRunning = false }
}

/// Main SwiftUI app scene.
///
/// NOTE: This type does NOT use `@main` — the Xcode app target's `main.swift` is
/// the entry point, so it can call `StimmgabelApp.main()` explicitly. This avoids
/// the `@main` / `main.swift` conflict when the SPM module is embedded in an app target.
public struct StimmgabelApp: App {

    @StateObject private var viewModel: AppViewModel

    public init() {
        // AppViewModel(convenience) creates the pipeline, output adapter, and
        // reads persisted mute state from UserDefaults before any consumer attaches
        // (ADR 0007).
        //
        // SystemAudioAdapter requires macOS 14.2; the convenience init is gated on it.
        // At runtime on 14.0–14.1 the app creates a no-op pipeline with only mic capture.
        if #available(macOS 14.2, *) {
            _viewModel = StateObject(wrappedValue: AppViewModel())
        } else {
            _viewModel = StateObject(wrappedValue: AppViewModel(pipeline: AudioPipeline(systemAudioAdapter: SilentAdapter())))
        }
    }

    public var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(viewModel)
        } label: {
            // Icon updates within one runloop cycle of a mute or state change
            // because viewModel is @StateObject and menuBarIconName is computed
            // from @Published properties (ADR 0007).
            Image(systemName: viewModel.menuBarIconName)
        }
    }
}
