/// Abstraction over a single upstream capture path (mic or system audio).
///
/// The adapter owns the lifecycle of the underlying CoreAudio resource (HAL IOProc or
/// Process Tap). `AudioPipeline` holds one instance per side and treats them symmetrically.
///
/// Conforming to this protocol is the seam that lets unit tests substitute
/// fakes for real CoreAudio resources (ADR 0009, Tier 1).
public protocol UpstreamCaptureAdapter: Sendable {
    /// Open the underlying CoreAudio resource and begin delivering audio buffers.
    /// Calling `start()` on an already-running adapter is a no-op.
    func start() throws

    /// Tear down the underlying CoreAudio resource and stop delivering buffers.
    /// Calling `stop()` on a stopped adapter is a no-op.
    func stop()

    /// Whether the adapter is currently running.
    var isRunning: Bool { get }
}
