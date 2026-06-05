import Foundation

/// States of the audio pipeline from the perspective of consumers.
public enum AudioPipelineState: Equatable, Sendable {
    /// No consumer is currently reading from the virtual mic.
    case idle
    /// A consumer has attached and both upstream adapters are running.
    case consumerAttached
}

/// Central coordinator of the audio data path.
///
/// Owns one `UpstreamCaptureAdapter` per side (mic and system audio) and a serial
/// state queue that serialises all lifecycle transitions (ADR 0010).
///
/// v1 mute behaviour: both adapters run whenever a consumer is attached; mute is
/// applied at the mix stage as a multiply-by-zero (ADR 0010, "zero in the mix").
public final class AudioPipeline: @unchecked Sendable {

    // MARK: - State

    private let queue = DispatchQueue(label: "com.innoq.stimmgabel.AudioPipeline.state")

    private(set) public var state: AudioPipelineState = .idle {
        didSet {
            guard oldValue != state else { return }
            stateDidChange?(state)
        }
    }

    /// Called on the serial state queue whenever `state` changes.
    public var stateDidChange: ((AudioPipelineState) -> Void)?

    // MARK: - Mute toggles (v1: mix-stage only)

    private var micMuted: Bool = false
    private var systemAudioMuted: Bool = false

    // MARK: - Adapters

    private let micAdapter: any UpstreamCaptureAdapter
    private let systemAudioAdapter: any UpstreamCaptureAdapter

    // MARK: - Init

    public init(
        micAdapter: any UpstreamCaptureAdapter,
        systemAudioAdapter: any UpstreamCaptureAdapter
    ) {
        self.micAdapter = micAdapter
        self.systemAudioAdapter = systemAudioAdapter
    }

    // MARK: - Consumer lifecycle

    /// Called when a downstream consumer attaches (e.g. the virtual mic device starts being read).
    /// Starts both upstream adapters if not already running.
    public func consumerAttached() {
        queue.sync {
            guard state == .idle else { return }
            try? micAdapter.start()
            try? systemAudioAdapter.start()
            state = .consumerAttached
        }
    }

    /// Called when the last downstream consumer detaches.
    /// Stops both upstream adapters.
    public func consumerDetached() {
        queue.sync {
            guard state == .consumerAttached else { return }
            micAdapter.stop()
            systemAudioAdapter.stop()
            state = .idle
        }
    }

    // MARK: - Mute (v1: mix-stage only, ADR 0010)

    /// Toggle the mute state for a single upstream side.
    ///
    /// v1: records the flag for use at the mix stage. Neither adapter is stopped.
    /// v2 upgrade point: also call `stop()` / `start()` on the affected adapter here
    /// (ADR 0010, "Revisit when").
    public func setSideMute(mic: Bool? = nil, systemAudio: Bool? = nil) {
        queue.sync {
            if let mic { micMuted = mic }
            if let systemAudio { systemAudioMuted = systemAudio }
        }
    }

    /// Returns whether the mic side is currently muted.
    public var isMicMuted: Bool {
        queue.sync { micMuted }
    }

    /// Returns whether the system-audio side is currently muted.
    public var isSystemAudioMuted: Bool {
        queue.sync { systemAudioMuted }
    }
}
