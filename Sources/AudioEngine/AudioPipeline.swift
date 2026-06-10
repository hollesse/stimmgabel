import AVFAudio
import Foundation
import os

/// States of the audio pipeline from the perspective of consumers.
public enum AudioPipelineState: Equatable, Sendable {
    case idle
    case consumerAttached
}

/// Coordinates the mic + system-audio capture → SHM data path.
///
/// Phase 2: both mic and system audio, no mute.
/// System audio's IOProc drives the mix timing (it fires at the hardware
/// clock rate and is already synchronized with coreaudiod).  The mic feeds
/// a staging FIFO; when the system audio callback fires it drains matching
/// mic frames, mixes them in, and writes the result to SHM.
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

    public var currentMicDeviceName: String {
        get { queue.sync { _micName } }
        set { queue.sync { _micName = newValue } }
    }
    private var _micName: String = ""

    public var deviceNamesDidChange: (() -> Void)?

    // MARK: - Adapters

    private let systemAudioAdapter: any UpstreamCaptureAdapter
    private let micAdapter: any UpstreamCaptureAdapter

    /// FIFO of interleaved mic samples drained on each system-audio IOProc call.
    private let micStaging = StagingBuffer()

    // MARK: - Gain

    /// Gain multiplier applied to the mic channel before mixing.
    /// Default 5.0: speech from a built-in mic (~0.05–0.15 amplitude) competes
    /// with system audio at full volume (~0.3–0.8 amplitude).
    /// Increase if mic is still inaudible; decrease if it clips (sounds distorted).
    public var micGain: Float = 3.0

    // MARK: - IPC sink

    var outputSink: ((Data, UInt32) -> Void)?
    private var _mixCallCount = 0
    private let log = Logger(subsystem: "com.innoq.stimmgabel", category: "AudioPipeline")

    // MARK: - Init

    public init(systemAudioAdapter: any UpstreamCaptureAdapter,
                micAdapter: any UpstreamCaptureAdapter) {
        self.systemAudioAdapter = systemAudioAdapter
        self.micAdapter         = micAdapter

        // System audio drives the mix — its IOProc fires at the hardware clock.
        systemAudioAdapter.onBuffer = { [weak self] buf in self?.forwardMixed(buf) }

        // Mic feeds the staging FIFO; drained on each system-audio callback.
        micAdapter.onBuffer = { [weak self] buf in self?.micStaging.store(buf) }
    }

    // MARK: - Consumer lifecycle

    public func consumerAttached() {
        queue.sync {
            guard state == .idle else { return }
            // System audio starts first (blocking, ~1 s) — consumer hears it immediately.
            try? systemAudioAdapter.start()
            _sysName = systemAudioAdapter.deviceName
            state = .consumerAttached
        }
        deviceNamesDidChange?()

        // Mic starts in the background — no blocking, mic audio joins the mix ~1–2 s later.
        // The micStaging FIFO delivers zeros until mic frames arrive (silence in mic channel).
        // Engine.stop() in MicAdapter.stop() ensures the indicator disappears on detach.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            try? self.micAdapter.start()
            self.queue.async { [weak self] in
                guard let self else { return }
                self._micName = self.micAdapter.deviceName
                self.deviceNamesDidChange?()
            }
        }
    }

    public func consumerDetached() {
        queue.sync {
            guard state == .consumerAttached else { return }
            systemAudioAdapter.stop()
            micAdapter.stop()
            _sysName = systemAudioAdapter.deviceName
            _micName = micAdapter.deviceName
            state = .idle
        }
        deviceNamesDidChange?()
    }

    // MARK: - Mix + forward

    /// Called on the system-audio IOProc thread with each system-audio buffer.
    /// Drains matching mic samples, mixes, and writes the result to SHM.
    private func forwardMixed(_ sysBuf: AVAudioPCMBuffer) {
        guard let sink = outputSink else { return }
        guard
            sysBuf.format.commonFormat == .pcmFormatFloat32,
            !sysBuf.format.isInterleaved,
            sysBuf.format.channelCount == 2,
            sysBuf.frameLength > 0,
            let sysL = sysBuf.floatChannelData?[0],
            let sysR = sysBuf.floatChannelData?[1]
        else { return }

        let n = Int(sysBuf.frameLength)

        // Drain mic samples from FIFO (zeros if mic hasn't delivered yet).
        let micSamples = micStaging.drain(frameCount: n)  // interleaved L,R,L,R,...

        // Diagnostic: log mic peak every ~94 calls (~1 s) so we can verify data flows.
        self._mixCallCount += 1
        if self._mixCallCount % 94 == 1 {
            let micPeak = micSamples.reduce(0 as Float) { max($0, abs($1)) }
            let sysPeak = (0..<n).reduce(0 as Float) { max($0, abs(sysL[$1])) }
            self.log.info("mix #\(self._mixCallCount): sysPeak=\(sysPeak, privacy: .public) micPeak=\(micPeak, privacy: .public)")
        }

        let gain = micGain
        var interleaved = [Float](repeating: 0, count: n * 2)
        for i in 0..<n {
            interleaved[i * 2]     = sysL[i] + micSamples[i * 2]     * gain
            interleaved[i * 2 + 1] = sysR[i] + micSamples[i * 2 + 1] * gain
        }
        let data = interleaved.withUnsafeBufferPointer { Data(buffer: $0) }
        sink(data, UInt32(n))
    }

    // MARK: - Legacy mix() for tests

    /// Returns silence. Only used by unit tests that exercise the pipeline directly.
    public func mix(frameCount: Int) -> [Float] {
        [Float](repeating: 0, count: frameCount * 2)
    }
}
