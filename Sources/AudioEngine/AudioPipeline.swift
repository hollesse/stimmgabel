import AVFAudio
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

    // MARK: - Observable consumer / device state

    /// `true` when a consumer is actively reading from the virtual mic.
    /// Updated on `consumerAttached()` / `consumerDetached()`.
    public var consumerActive: Bool {
        queue.sync { state == .consumerAttached }
    }

    /// Human-readable name of the current default input device (sourced from `MicAdapter`).
    /// Empty when the adapter is not running.
    public var currentMicDeviceName: String {
        get { queue.sync { _currentMicDeviceName } }
        set { queue.sync { _currentMicDeviceName = newValue } }
    }
    private var _currentMicDeviceName: String = ""

    /// Human-readable name of the current default output device (sourced from `SystemAudioAdapter`).
    /// Empty when the adapter is not running.
    public var currentSystemAudioDeviceName: String {
        get { queue.sync { _currentSystemAudioDeviceName } }
        set { queue.sync { _currentSystemAudioDeviceName = newValue } }
    }
    private var _currentSystemAudioDeviceName: String = ""

    /// Called on the serial state queue whenever device names change.
    public var deviceNamesDidChange: (() -> Void)?

    // MARK: - Buffer callbacks (pass-through, v1)

    /// Called on each render cycle with the system-audio buffer (mix target format).
    /// The handler may be called on any thread (the adapter's render thread).
    public var onSystemAudioBuffer: ((AVAudioPCMBuffer) -> Void)? {
        didSet {
            let passThrough = onSystemAudioBuffer
            systemAudioAdapter.onBuffer = { [weak self] buf in
                self?.mixer.receiveSysAudio(buf)
                passThrough?(buf)
            }
        }
    }

    /// Called on each render cycle with the mic buffer (mix target format).
    /// The handler may be called on any thread (the adapter's render thread).
    public var onMicBuffer: ((AVAudioPCMBuffer) -> Void)? {
        didSet {
            let passThrough = onMicBuffer
            micAdapter.onBuffer = { [weak self] buf in
                self?.mixer.receiveMic(buf)
                passThrough?(buf)
            }
        }
    }

    // MARK: - Mixer (mix stage, ADR 0010)

    private let mixer = Mixer()

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
        // Wire adapters to the mixer's staging buffers immediately.
        // Any onMicBuffer / onSystemAudioBuffer pass-through handlers are overlaid
        // when the caller sets those properties (see property observers above).
        micAdapter.onBuffer = { [weak self] buf in self?.mixer.receiveMic(buf) }
        systemAudioAdapter.onBuffer = { [weak self] buf in self?.mixer.receiveSysAudio(buf) }
    }

    // MARK: - Consumer lifecycle

    /// Called when a downstream consumer attaches (e.g. the virtual mic device starts being read).
    /// Starts both upstream adapters if not already running.
    public func consumerAttached() {
        queue.sync {
            guard state == .idle else { return }
            try? micAdapter.start()
            try? systemAudioAdapter.start()
            _currentMicDeviceName = micAdapter.deviceName
            _currentSystemAudioDeviceName = systemAudioAdapter.deviceName
            state = .consumerAttached
        }
        deviceNamesDidChange?()
    }

    /// Called when the last downstream consumer detaches.
    /// Stops both upstream adapters.
    public func consumerDetached() {
        queue.sync {
            guard state == .consumerAttached else { return }
            micAdapter.stop()
            systemAudioAdapter.stop()
            _currentMicDeviceName = micAdapter.deviceName
            _currentSystemAudioDeviceName = systemAudioAdapter.deviceName
            state = .idle
        }
        deviceNamesDidChange?()
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

    // MARK: - Mix (output adapter entry point, ADR 0010)

    /// Drain both per-side staging buffers and produce a mixed output buffer.
    ///
    /// This method is designed to be called by the output adapter on the driver's
    /// DoIOOperation thread each render cycle.
    ///
    /// - Parameter frameCount: Number of stereo frames to produce.
    /// - Returns: An interleaved float32 array of `frameCount * 2` samples (L, R, L, R, …).
    ///   If a side has not yet delivered a buffer it is treated as silence.
    ///   Muted sides contribute zero.
    public func mix(frameCount: Int) -> [Float] {
        let (micMute, sysAudioMute) = queue.sync { (micMuted, systemAudioMuted) }
        return mixer.mix(
            frameCount: frameCount,
            micMuted: micMute,
            systemAudioMuted: sysAudioMute
        )
    }
}
