import AVFAudio

// MicAdapter is no longer used in production.
// Microphone capture is now handled directly inside SystemAudioAdapter via a
// combined CoreAudio aggregate device (tap + mic sub-device).
//
// This file is kept only so that test helpers that reference MicAdapter
// continue to compile until they are updated.

@available(*, deprecated, message: "Use SystemAudioAdapter — mic is captured in the aggregate device")
public final class MicAdapter: UpstreamCaptureAdapter, @unchecked Sendable {
    public private(set) var isRunning = false
    public var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    public private(set) var deviceName: String = ""
    public init() {}
    public func start() throws { isRunning = true }
    public func stop() { isRunning = false }
}
