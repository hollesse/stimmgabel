import Foundation
import AudioEngine

/// Central observable state for the menu-bar UI.
///
/// Phase 3: system audio + mic captured in one aggregate device inside
/// SystemAudioAdapter.  No separate MicAdapter.
@MainActor
public final class AppViewModel: ObservableObject {

    @Published public internal(set) var pipelineState: AudioPipelineState = .idle

    public var consumerActive: Bool { pipelineState == .consumerAttached }

    public var consumerStatusDisplayString: String {
        consumerActive ? "Active" : "Idle — no app reading"
    }

    public var currentSystemAudioDeviceName: String {
        pipeline.currentSystemAudioDeviceName
    }

    let pipeline: AudioPipeline
    private let outputAdapter: DriverOutputAdapter?

    @available(macOS 14.2, *)
    public convenience init() {
        let pipeline = AudioPipeline(systemAudioAdapter: SystemAudioAdapter())
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

    public var menuBarIconName: String {
        pipelineState == .idle ? "waveform.slash" : "waveform"
    }
}
