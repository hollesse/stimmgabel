import XCTest
import AVFAudio
@testable import AudioEngine

// MARK: - FakeUpstreamCaptureAdapter (shared test double, ADR 0009)

final class FakeUpstreamCaptureAdapter: UpstreamCaptureAdapter, @unchecked Sendable {
    private(set) var startCallCount: Int = 0
    private(set) var stopCallCount: Int = 0
    private(set) var isRunning: Bool = false
    var deviceName: String = ""
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    func start() throws {
        guard !isRunning else { return }
        startCallCount += 1
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        stopCallCount += 1
        isRunning = false
    }

    func emitBuffer(_ buffer: AVAudioPCMBuffer) { onBuffer?(buffer) }
}

// MARK: - AudioPipeline tests

final class AudioPipelineTests: XCTestCase {

    private func makePipeline() -> (AudioPipeline, FakeUpstreamCaptureAdapter) {
        let sysAudio = FakeUpstreamCaptureAdapter()
        let mic      = FakeUpstreamCaptureAdapter()
        return (AudioPipeline(systemAudioAdapter: sysAudio, micAdapter: mic), sysAudio)
    }

    private func makeStereoBuffer(frameCount: Int, value: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 48_000, channels: 2, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buf.frameLength = AVAudioFrameCount(frameCount)
        if let data = buf.floatChannelData {
            for ch in 0..<2 { for i in 0..<frameCount { data[ch][i] = value } }
        }
        return buf
    }

    // MARK: State

    func test_initialState_isIdle() {
        let (pipeline, _) = makePipeline()
        XCTAssertEqual(pipeline.state, .idle)
    }

    func test_consumerAttached_transitionsToConsumerAttached() {
        let (pipeline, _) = makePipeline()
        pipeline.consumerAttached()
        XCTAssertEqual(pipeline.state, .consumerAttached)
    }

    func test_consumerDetached_transitionsBackToIdle() {
        let (pipeline, _) = makePipeline()
        pipeline.consumerAttached()
        pipeline.consumerDetached()
        XCTAssertEqual(pipeline.state, .idle)
    }

    func test_consumerAttached_startsSystemAudioAdapter() {
        let (pipeline, sysAudio) = makePipeline()
        pipeline.consumerAttached()
        XCTAssertTrue(sysAudio.isRunning)
        XCTAssertEqual(sysAudio.startCallCount, 1)
    }

    func test_consumerDetached_stopsSystemAudioAdapter() {
        let (pipeline, sysAudio) = makePipeline()
        pipeline.consumerAttached()
        pipeline.consumerDetached()
        XCTAssertFalse(sysAudio.isRunning)
        XCTAssertEqual(sysAudio.stopCallCount, 1)
    }

    func test_consumerAttachedTwice_startsAdapterOnlyOnce() {
        let (pipeline, sysAudio) = makePipeline()
        pipeline.consumerAttached()
        pipeline.consumerAttached()
        XCTAssertEqual(sysAudio.startCallCount, 1)
    }

    func test_consumerDetachedWhenIdle_isNoOp() {
        let (pipeline, sysAudio) = makePipeline()
        pipeline.consumerDetached()
        XCTAssertEqual(pipeline.state, .idle)
        XCTAssertEqual(sysAudio.stopCallCount, 0)
    }

    func test_stateDidChange_calledOnAttachAndDetach() {
        let (pipeline, _) = makePipeline()
        var observed: [AudioPipelineState] = []
        pipeline.stateDidChange = { observed.append($0) }
        pipeline.consumerAttached()
        pipeline.consumerDetached()
        XCTAssertEqual(observed, [.consumerAttached, .idle])
    }

    // MARK: Mix

    // MARK: - Mix tests (system audio + mic)

    func test_sysAudio_reachesOutput() {
        let (pipeline, sysAudio) = makePipeline()
        var received: [Float] = []
        pipeline.outputSink = { data, _ in
            data.withUnsafeBytes { received = Array($0.bindMemory(to: Float.self)) }
        }
        pipeline.consumerAttached()
        sysAudio.emitBuffer(makeStereoBuffer(frameCount: 512, value: 0.5))
        XCTAssertFalse(received.isEmpty, "outputSink must be called when sys audio arrives")
        // All samples should be ≈ 0.5 (sys only, no mic)
        XCTAssertTrue(received.allSatisfy { abs($0 - 0.5) < 1e-5 },
                      "Expected sys audio 0.5, got \(received.prefix(3))")
    }

    func test_mic_reachesOutput_mixedWithSysAudio() {
        // This is the regression test for the Phase 2 mic mixing.
        // When a mic buffer arrives BEFORE the sys audio IOProc fires, its samples
        // should appear summed into the output.
        let sysAudio = FakeUpstreamCaptureAdapter()
        let mic      = FakeUpstreamCaptureAdapter()
        let pipeline = AudioPipeline(systemAudioAdapter: sysAudio, micAdapter: mic)

        var received: [Float] = []
        pipeline.outputSink = { data, _ in
            data.withUnsafeBytes { received = Array($0.bindMemory(to: Float.self)) }
        }
        pipeline.consumerAttached()

        // Emit mic audio first — goes into micStaging FIFO
        mic.emitBuffer(makeStereoBuffer(frameCount: 512, value: 0.3))

        // Emit sys audio — triggers forwardMixed() which drains micStaging
        sysAudio.emitBuffer(makeStereoBuffer(frameCount: 512, value: 0.5))

        XCTAssertFalse(received.isEmpty, "outputSink must be called")
        // Expected: sys(0.5) + mic(0.3) = 0.8 for every sample
        let peak = received.map(abs).max() ?? 0
        XCTAssertGreaterThan(peak, 0.7,
            "Mic audio not mixed in — peak=\(peak), expected ≈ 0.8 (0.5 sys + 0.3 mic). " +
            "Check that micStaging.drain() returns mic samples in forwardMixed().")
        XCTAssertTrue(received.allSatisfy { abs($0 - 0.8) < 1e-5 },
            "Expected sys(0.5)+mic(0.3)=0.8, got \(received.prefix(3))")
    }

    func test_mic_withoutSysAudio_doesNotCallOutputSink() {
        // Without sys audio, forwardMixed() is never called → no output.
        // Mic-only audio goes into staging but never drains — this is by design
        // (sys audio drives the output timing).
        let sysAudio = FakeUpstreamCaptureAdapter()
        let mic      = FakeUpstreamCaptureAdapter()
        let pipeline = AudioPipeline(systemAudioAdapter: sysAudio, micAdapter: mic)

        var called = false
        pipeline.outputSink = { _, _ in called = true }
        pipeline.consumerAttached()

        mic.emitBuffer(makeStereoBuffer(frameCount: 512, value: 0.9))
        XCTAssertFalse(called, "Without sys audio IOProc, outputSink must not fire")
    }

    func test_noOutputSink_emitBuffer_doesNotCrash() {
        let (pipeline, sysAudio) = makePipeline()
        pipeline.consumerAttached()
        sysAudio.emitBuffer(makeStereoBuffer(frameCount: 256, value: 0.9))
        XCTAssertNil(pipeline.outputSink)
    }

    // MARK: Adapter conformance checks

    @available(macOS 14.2, *)
    func test_systemAudioAdapter_conformsToProtocol() {
        let _: any UpstreamCaptureAdapter = SystemAudioAdapter()
    }

    @available(macOS 14.2, *)
    func test_systemAudioAdapter_notRunning_afterInit() {
        XCTAssertFalse(SystemAudioAdapter().isRunning)
    }

    func test_fakeAdapter_emitBuffer_callsHandler() {
        let adapter = FakeUpstreamCaptureAdapter()
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: 48_000, channels: 2, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 512)!
        buf.frameLength = 512
        var received: AVAudioPCMBuffer?
        adapter.onBuffer = { received = $0 }
        adapter.emitBuffer(buf)
        XCTAssertNotNil(received)
    }
}
