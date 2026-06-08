import AVFAudio
import Foundation

/// Thread-safe FIFO of interleaved float32 stereo samples.
///
/// The adapter thread appends via `store()`.  The render thread consumes via `drain(frameCount:)`.
/// Both sides access the internal buffer under a lock held only for the copy — never across
/// audio-processing loops.
final class StagingBuffer: @unchecked Sendable {

    private var lock    = os_unfair_lock()
    private var samples = [Float]()          // interleaved L,R,L,R,...

    /// Append all frames from a non-interleaved float32 stereo buffer.
    func store(_ buffer: AVAudioPCMBuffer) {
        guard
            buffer.format.commonFormat == .pcmFormatFloat32,
            !buffer.format.isInterleaved,
            buffer.format.channelCount == 2,
            buffer.frameLength > 0,
            let data = buffer.floatChannelData
        else { return }

        let n   = Int(buffer.frameLength)
        let ch0 = data[0]
        let ch1 = data[1]
        var interleaved = [Float](repeating: 0, count: n * 2)
        for i in 0..<n {
            interleaved[i * 2]     = ch0[i]
            interleaved[i * 2 + 1] = ch1[i]
        }

        os_unfair_lock_lock(&lock)
        samples.append(contentsOf: interleaved)
        // Cap backlog at 4096 stereo frames (85 ms) to prevent unbounded growth.
        let maxSamples = 4096 * 2
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
        os_unfair_lock_unlock(&lock)
    }

    /// Consume up to `frameCount` frames from the front of the FIFO.
    /// Returns `frameCount * 2` interleaved samples; zero-pads if fewer are available.
    func drain(frameCount: Int) -> [Float] {
        let needed = frameCount * 2
        os_unfair_lock_lock(&lock)
        let available = min(needed, samples.count)
        let result    = Array(samples.prefix(available))
        if available > 0 { samples.removeFirst(available) }
        os_unfair_lock_unlock(&lock)

        if result.count == needed { return result }
        var padded = result
        padded.append(contentsOf: [Float](repeating: 0, count: needed - result.count))
        return padded
    }

    /// Whether there are any samples currently buffered.
    var isEmpty: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return samples.isEmpty
    }
}

/// Passes system audio from its staging buffer to the render thread.
///
/// Phase 1: system audio only — no mic, no mute.
public final class Mixer: @unchecked Sendable {

    private let staging = StagingBuffer()

    public init() {}

    public func receiveSysAudio(_ buffer: AVAudioPCMBuffer) {
        staging.store(buffer)
    }

    /// Drain `frameCount` frames from the staging FIFO.
    /// Returns `frameCount * 2` interleaved float32 samples; zeros if no data available.
    public func mix(frameCount: Int) -> [Float] {
        staging.drain(frameCount: frameCount)
    }
}
