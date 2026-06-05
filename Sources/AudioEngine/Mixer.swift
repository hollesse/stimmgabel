import AVFAudio
import Foundation

/// A per-side staging buffer that accepts `AVAudioPCMBuffer` deliveries from an adapter
/// thread and exposes a drain method safe to call from a different (driver) thread.
///
/// Thread safety: a simple `os_unfair_lock` guards the stored samples. The lock is held
/// only briefly during copy-in and copy-out, never across an audio-processing loop.
final class StagingBuffer: @unchecked Sendable {

    private var lock = os_unfair_lock()
    private var samples: [Float] = []

    /// Replace the stored samples with a copy of the non-interleaved buffer's data,
    /// interleaved as [ch0[0], ch1[0], ch0[1], ch1[1], ...].
    ///
    /// Only float32, non-interleaved stereo buffers are accepted (mix target format).
    func store(_ buffer: AVAudioPCMBuffer) {
        guard
            buffer.format.commonFormat == .pcmFormatFloat32,
            !buffer.format.isInterleaved,
            buffer.format.channelCount == 2,
            buffer.frameLength > 0,
            let data = buffer.floatChannelData
        else { return }

        let frameCount = Int(buffer.frameLength)
        var interleaved = [Float](repeating: 0, count: frameCount * 2)
        let ch0 = data[0]
        let ch1 = data[1]
        for i in 0..<frameCount {
            interleaved[i * 2]     = ch0[i]
            interleaved[i * 2 + 1] = ch1[i]
        }

        os_unfair_lock_lock(&lock)
        samples = interleaved
        os_unfair_lock_unlock(&lock)
    }

    /// Return a copy of the stored samples (already interleaved).
    /// Returns `nil` if no buffer has been stored yet (adapter hasn't produced one).
    func drain() -> [Float]? {
        os_unfair_lock_lock(&lock)
        let copy = samples.isEmpty ? nil : samples
        os_unfair_lock_unlock(&lock)
        return copy
    }
}

/// Combines the mic and system-audio sides into a single interleaved float32 stereo buffer.
///
/// The mix step (ADR 0010):
/// - Accepts asynchronous buffer deliveries from both upstream adapters via `receiveMic` /
///   `receiveSysAudio`. These may be called on any thread (the adapter's render thread).
/// - Produces a mixed buffer on demand via `mix(frameCount:micMuted:systemAudioMuted:)`,
///   which is driven by the output adapter's render thread.
/// - Applies per-side mute as multiply-by-zero (v1). A v1 gain slot is kept in the add
///   path (`micGain * mic[i] + sysaudioGain * sysaudio[i]`) so v2 can wire gain values
///   without restructuring.
/// - Treats a missing side (no buffer delivered yet) as silence.
public final class Mixer: @unchecked Sendable {

    // MARK: Staging buffers

    private let micStaging = StagingBuffer()
    private let sysAudioStaging = StagingBuffer()

    // MARK: Gain slots (v1: both 1.0; v2 upgrade point)

    /// Per-side gain applied at the mix stage. Default 1.0 (unity).
    public var micGain: Float = 1.0
    public var sysAudioGain: Float = 1.0

    // MARK: Lifecycle

    public init() {}

    // MARK: Receiving

    /// Called by the mic adapter on each render cycle.
    public func receiveMic(_ buffer: AVAudioPCMBuffer) {
        micStaging.store(buffer)
    }

    /// Called by the system-audio adapter on each render cycle.
    public func receiveSysAudio(_ buffer: AVAudioPCMBuffer) {
        sysAudioStaging.store(buffer)
    }

    // MARK: Producing

    /// Drain both staging buffers and produce a mixed output.
    ///
    /// - Parameters:
    ///   - frameCount: Number of stereo frames to produce.
    ///   - micMuted: If `true`, the mic contribution is treated as zero.
    ///   - systemAudioMuted: If `true`, the system-audio contribution is treated as zero.
    /// - Returns: An interleaved float32 array of `frameCount * 2` samples (L, R, L, R, …).
    ///   Each sample position: `output[i] = micGain * mic[i] + sysAudioGain * sysaudio[i]`
    ///   where muted sides contribute 0.
    public func mix(
        frameCount: Int,
        micMuted: Bool,
        systemAudioMuted: Bool
    ) -> [Float] {
        let sampleCount = frameCount * 2
        let micSamples = micStaging.drain()
        let sysAudioSamples = sysAudioStaging.drain()

        var output = [Float](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            let micSample: Float
            if micMuted {
                micSample = 0
            } else if let m = micSamples, i < m.count {
                micSample = micGain * m[i]
            } else {
                micSample = 0
            }

            let sysAudioSample: Float
            if systemAudioMuted {
                sysAudioSample = 0
            } else if let s = sysAudioSamples, i < s.count {
                sysAudioSample = sysAudioGain * s[i]
            } else {
                sysAudioSample = 0
            }

            output[i] = micSample + sysAudioSample
        }
        return output
    }
}
