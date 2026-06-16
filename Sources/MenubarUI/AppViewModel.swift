import Foundation
import AudioEngine

/// Central observable state for the menu-bar UI.
///
/// Phase 2: mic + system audio, no mute.
@MainActor
public final class AppViewModel: ObservableObject {

    @Published public internal(set) var pipelineState: AudioPipelineState = .idle

    /// System audio gain, range 0.0–2.0. Default 1.0, not persisted.
    @Published public var sysAudioGain: Float = 1.0 {
        didSet { pipeline.sysAudioGain = sysAudioGain }
    }

    /// Mic gain, range 0.0–6.0. Default 3.0 (normalized: 100%), not persisted.
    /// Formula for display: Int(micGain / 3.0 * 100)%.
    @Published public var micGain: Float = 3.0 {
        didSet { pipeline.micGain = micGain }
    }

    public var consumerActive: Bool { pipelineState == .consumerAttached }

    public var consumerStatusDisplayString: String {
        consumerActive ? "Active" : "Idle — no app reading"
    }

    public var currentMicDeviceName: String {
        pipeline.currentMicDeviceName
    }

    public var currentSystemAudioDeviceName: String {
        pipeline.currentSystemAudioDeviceName
    }

    let pipeline: AudioPipeline
    private let outputAdapter: DriverOutputAdapter?

    @available(macOS 14.2, *)
    public convenience init() {
        // Request mic permission early so the system dialog appears before any
        // consumer attaches. installTap in MicAdapter.start() is gated on .authorized.
        MicAdapter.requestPermission()
        let mic = MicAdapter()
        // Pre-install the tap now (deferred to next runloop tick inside prepare())
        // so consumer-attach only pays engine.start() cost (~400ms) instead of
        // also installTap (~450ms). Cuts the consumer-attach mic latency roughly
        // in half.
        mic.prepare()
        let pipeline = AudioPipeline(
            systemAudioAdapter: SystemAudioAdapter(),
            micAdapter: mic
        )
        self.init(pipeline: pipeline, outputAdapter: DriverOutputAdapter(pipeline: pipeline))
    }

    public init(pipeline: AudioPipeline, outputAdapter: DriverOutputAdapter? = nil) {
        self.pipeline      = pipeline
        self.outputAdapter = outputAdapter


        pipeline.stateDidChange = { [weak self] newState in
            Task { @MainActor [weak self] in self?.pipelineState = newState }
        }
        pipeline.deviceNamesDidChange = { [weak self] in
            Task { @MainActor [weak self] in self?.objectWillChange.send() }
        }
        pipelineState = pipeline.state
    }

    /// Asset-catalog name of the menu-bar icon for the current pipeline state.
    ///
    /// Returns custom asset names (`MenubarIdle` / `MenubarActive`) defined in
    /// `App/Stimmgabel/Assets.xcassets`. Both assets are template images, so
    /// the menu bar tints them automatically for light/dark + selected states
    /// (menubar-ui-006).
    public var menuBarIconName: String {
        pipelineState == .idle ? "MenubarIdle" : "MenubarActive"
    }
}
