import Foundation
import AudioEngine
import AVFoundation

/// Central observable state for the menu-bar UI.
///
/// Phase 2: mic + system audio, no mute.
@MainActor
public final class AppViewModel: ObservableObject {

    @Published public internal(set) var pipelineState: AudioPipelineState = .idle

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
        let pipeline = AudioPipeline(
            systemAudioAdapter: SystemAudioAdapter(),
            micAdapter: MicAdapter()
        )
        self.init(pipeline: pipeline, outputAdapter: DriverOutputAdapter(pipeline: pipeline))
    }

    public init(pipeline: AudioPipeline, outputAdapter: DriverOutputAdapter? = nil) {
        self.pipeline      = pipeline
        self.outputAdapter = outputAdapter

        // Request microphone permission early so the TCC grant propagates into the
        // CoreAudio HAL before the first consumer attaches.  Without this, the first
        // AVCaptureDevice grant races with AudioDeviceStart → the HAL hangs waiting
        // for permission confirmation → DriverOutputAdapter.queue deadlocks.
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }

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
