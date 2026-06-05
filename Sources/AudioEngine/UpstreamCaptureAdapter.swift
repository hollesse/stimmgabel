import AVFAudio

/// Abstraction over a single upstream capture path (mic or system audio).
///
/// The adapter owns the lifecycle of the underlying CoreAudio resource (HAL IOProc or
/// Process Tap). `AudioPipeline` holds one instance per side and treats them symmetrically.
///
/// Conforming to this protocol is the seam that lets unit tests substitute
/// fakes for real CoreAudio resources (ADR 0009, Tier 1).
///
/// Buffer delivery: the adapter calls `onBuffer` on each render cycle with an
/// `AVAudioPCMBuffer` in the mix target format (48 kHz / float32 / non-interleaved stereo).
/// The handler is installed by the owner (typically `AudioPipeline`) before `start()`.
public protocol UpstreamCaptureAdapter: AnyObject, Sendable {
    /// Open the underlying CoreAudio resource and begin delivering audio buffers.
    /// Calling `start()` on an already-running adapter is a no-op.
    func start() throws

    /// Tear down the underlying CoreAudio resource and stop delivering buffers.
    /// Calling `stop()` on a stopped adapter is a no-op.
    func stop()

    /// Whether the adapter is currently running.
    var isRunning: Bool { get }

    /// Called by the adapter on every render cycle with a buffer in the mix target format.
    /// Set this before calling `start()`. The handler may be called on any thread.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)? { get set }

    /// Human-readable name of the current underlying CoreAudio device.
    /// Empty string when the adapter is not running or the name cannot be resolved.
    var deviceName: String { get }
}
