import AVFAudio
import Foundation

/// States of the audio pipeline from the perspective of consumers.
public enum AudioPipelineState: Equatable, Sendable {
    case idle
    case consumerAttached
}

/// Coordinates the system-audio capture → SHM data path.
///
/// Phase 1: system audio only, no mic, no mute, no render timer.
/// Audio is written to SHM directly from the IOProc callback so the write
/// clock is locked to coreaudiod's hardware clock — the same clock the driver
/// uses for DoIOOperation.  This eliminates the software/hardware clock drift
/// that caused robotic stuttering when using a DispatchSource render timer.
public final class AudioPipeline: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.innoq.stimmgabel.AudioPipeline.state")

    private(set) public var state: AudioPipelineState = .idle {
        didSet { guard oldValue != state else { return }; stateDidChange?(state) }
    }
    public var stateDidChange: ((AudioPipelineState) -> Void)?
    public var consumerActive: Bool { queue.sync { state == .consumerAttached } }

    public var currentSystemAudioDeviceName: String {
        get { queue.sync { _name } }
        set { queue.sync { _name = newValue } }
    }
    private var _name: String = ""
    public var deviceNamesDidChange: (() -> Void)?

    private let systemAudioAdapter: any UpstreamCaptureAdapter

    /// Set by `DriverOutputAdapter` while a consumer is active.
    /// Called on each IOProc tick with interleaved float32 stereo data + frame count.
    var outputSink: ((Data, UInt32) -> Void)?

    public init(systemAudioAdapter: any UpstreamCaptureAdapter) {
        self.systemAudioAdapter = systemAudioAdapter
        systemAudioAdapter.onBuffer = { [weak self] buf in self?.forward(buf) }
    }

    public func consumerAttached() {
        queue.sync {
            guard state == .idle else { return }
            try? systemAudioAdapter.start()
            _name = systemAudioAdapter.deviceName
            state = .consumerAttached
        }
        deviceNamesDidChange?()
    }

    public func consumerDetached() {
        queue.sync {
            guard state == .consumerAttached else { return }
            systemAudioAdapter.stop()
            _name = systemAudioAdapter.deviceName
            state = .idle
        }
        deviceNamesDidChange?()
    }

    // MARK: - Direct forwarding (replaces render timer + staging buffer)

    /// Called on the IOProc thread when the system-audio adapter delivers a buffer.
    /// Converts to interleaved float32 and writes directly to the SHM sink.
    private func forward(_ buf: AVAudioPCMBuffer) {
        guard let sink = outputSink else { return }
        guard
            buf.format.commonFormat == .pcmFormatFloat32,
            !buf.format.isInterleaved,
            buf.format.channelCount == 2,
            buf.frameLength > 0,
            let ch0 = buf.floatChannelData?[0],
            let ch1 = buf.floatChannelData?[1]
        else { return }

        let n = Int(buf.frameLength)
        var interleaved = [Float](repeating: 0, count: n * 2)
        for i in 0..<n {
            interleaved[i * 2]     = ch0[i]
            interleaved[i * 2 + 1] = ch1[i]
        }
        let data = interleaved.withUnsafeBufferPointer { Data(buffer: $0) }
        sink(data, UInt32(n))
    }

    // MARK: - Legacy mix() for tests that exercise the pipeline directly

    /// Returns interleaved float32 stereo silence.  Only used by unit tests;
    /// production code drives writes via `outputSink`.
    public func mix(frameCount: Int) -> [Float] {
        [Float](repeating: 0, count: frameCount * 2)
    }
}
