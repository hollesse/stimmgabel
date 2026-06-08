import AVFAudio
import Foundation
import os

/// States of the audio pipeline from the perspective of consumers.
public enum AudioPipelineState: Equatable, Sendable {
    case idle
    case consumerAttached
}

/// Coordinates the combined (system audio + mic) capture → SHM data path.
///
/// Phase 3 architecture: a single adapter (SystemAudioAdapter) captures both
/// system audio and microphone via a single CoreAudio aggregate device.  The
/// IOProc callback delivers already-mixed buffers, which are written to SHM
/// without any additional staging or mixing in this class.
public final class AudioPipeline: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.innoq.stimmgabel.AudioPipeline.state")

    private(set) public var state: AudioPipelineState = .idle {
        didSet { guard oldValue != state else { return }; stateDidChange?(state) }
    }
    public var stateDidChange: ((AudioPipelineState) -> Void)?
    public var consumerActive: Bool { queue.sync { state == .consumerAttached } }

    public var currentSystemAudioDeviceName: String {
        get { queue.sync { _sysName } }
        set { queue.sync { _sysName = newValue } }
    }
    private var _sysName: String = ""

    public var deviceNamesDidChange: (() -> Void)?

    private let systemAudioAdapter: any UpstreamCaptureAdapter

    // MARK: - IPC sink

    var outputSink: ((Data, UInt32) -> Void)?
    private var _mixCallCount = 0
    private let log = Logger(subsystem: "com.innoq.stimmgabel", category: "AudioPipeline")

    // MARK: - Init

    public init(systemAudioAdapter: any UpstreamCaptureAdapter) {
        self.systemAudioAdapter = systemAudioAdapter
        systemAudioAdapter.onBuffer = { [weak self] buf in self?.forward(buf) }
    }

    // MARK: - Consumer lifecycle

    public func consumerAttached() {
        queue.sync {
            guard state == .idle else { return }
            try? systemAudioAdapter.start()
            _sysName = systemAudioAdapter.deviceName
            state = .consumerAttached
        }
        deviceNamesDidChange?()
    }

    public func consumerDetached() {
        queue.sync {
            guard state == .consumerAttached else { return }
            systemAudioAdapter.stop()
            _sysName = systemAudioAdapter.deviceName
            state = .idle
        }
        deviceNamesDidChange?()
    }

    // MARK: - Forward to SHM

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

        self._mixCallCount += 1
        if self._mixCallCount % 94 == 1 {
            let peak = (0..<n).reduce(0 as Float) { max($0, abs(ch0[$1])) }
            self.log.info("forward #\(self._mixCallCount): peak=\(peak, privacy: .public)")
        }

        var interleaved = [Float](repeating: 0, count: n * 2)
        for i in 0..<n {
            interleaved[i * 2]     = ch0[i]
            interleaved[i * 2 + 1] = ch1[i]
        }
        let data = interleaved.withUnsafeBufferPointer { Data(buffer: $0) }
        sink(data, UInt32(n))
    }

    // MARK: - Legacy mix() for tests

    public func mix(frameCount: Int) -> [Float] {
        [Float](repeating: 0, count: frameCount * 2)
    }
}
