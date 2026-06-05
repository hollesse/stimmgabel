import XCTest
import AVFAudio
@testable import AudioEngine

// MARK: - Fake adapter (Tier 1, ADR 0009)

/// A controllable fake that records `start()` / `stop()` calls for assertion
/// and can emit synthetic buffers via `emitBuffer(_:)` for pipeline mix tests.
final class FakeUpstreamCaptureAdapter: UpstreamCaptureAdapter, @unchecked Sendable {
    private(set) var startCallCount: Int = 0
    private(set) var stopCallCount: Int = 0
    private(set) var isRunning: Bool = false

    /// Buffer handler installed by the owner (e.g. AudioPipeline).
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

    /// Test helper: push a synthetic buffer to the registered handler.
    func emitBuffer(_ buffer: AVAudioPCMBuffer) {
        onBuffer?(buffer)
    }
}

// MARK: - Tests

final class AudioPipelineTests: XCTestCase {

    // MARK: Initial state

    func test_initialState_isIdle() {
        let mic = FakeUpstreamCaptureAdapter()
        let sysAudio = FakeUpstreamCaptureAdapter()
        let pipeline = AudioPipeline(micAdapter: mic, systemAudioAdapter: sysAudio)

        XCTAssertEqual(pipeline.state, .idle)
    }

    // MARK: Consumer attach / detach

    func test_consumerAttached_transitionsToConsumerAttached() throws {
        let mic = FakeUpstreamCaptureAdapter()
        let sysAudio = FakeUpstreamCaptureAdapter()
        let pipeline = AudioPipeline(micAdapter: mic, systemAudioAdapter: sysAudio)

        pipeline.consumerAttached()

        XCTAssertEqual(pipeline.state, .consumerAttached)
    }

    func test_consumerAttached_startsBothAdapters() throws {
        let mic = FakeUpstreamCaptureAdapter()
        let sysAudio = FakeUpstreamCaptureAdapter()
        let pipeline = AudioPipeline(micAdapter: mic, systemAudioAdapter: sysAudio)

        pipeline.consumerAttached()

        XCTAssertTrue(mic.isRunning)
        XCTAssertTrue(sysAudio.isRunning)
        XCTAssertEqual(mic.startCallCount, 1)
        XCTAssertEqual(sysAudio.startCallCount, 1)
    }

    func test_consumerDetached_transitionsBackToIdle() {
        let mic = FakeUpstreamCaptureAdapter()
        let sysAudio = FakeUpstreamCaptureAdapter()
        let pipeline = AudioPipeline(micAdapter: mic, systemAudioAdapter: sysAudio)

        pipeline.consumerAttached()
        pipeline.consumerDetached()

        XCTAssertEqual(pipeline.state, .idle)
    }

    func test_consumerDetached_stopsBothAdapters() {
        let mic = FakeUpstreamCaptureAdapter()
        let sysAudio = FakeUpstreamCaptureAdapter()
        let pipeline = AudioPipeline(micAdapter: mic, systemAudioAdapter: sysAudio)

        pipeline.consumerAttached()
        pipeline.consumerDetached()

        XCTAssertFalse(mic.isRunning)
        XCTAssertFalse(sysAudio.isRunning)
        XCTAssertEqual(mic.stopCallCount, 1)
        XCTAssertEqual(sysAudio.stopCallCount, 1)
    }

    // MARK: Idempotency

    func test_consumerAttachedTwice_startsAdaptersOnlyOnce() {
        let mic = FakeUpstreamCaptureAdapter()
        let sysAudio = FakeUpstreamCaptureAdapter()
        let pipeline = AudioPipeline(micAdapter: mic, systemAudioAdapter: sysAudio)

        pipeline.consumerAttached()
        pipeline.consumerAttached() // second call should be a no-op

        XCTAssertEqual(mic.startCallCount, 1)
        XCTAssertEqual(sysAudio.startCallCount, 1)
    }

    func test_consumerDetachedWhenIdle_isNoOp() {
        let mic = FakeUpstreamCaptureAdapter()
        let sysAudio = FakeUpstreamCaptureAdapter()
        let pipeline = AudioPipeline(micAdapter: mic, systemAudioAdapter: sysAudio)

        pipeline.consumerDetached() // called while idle — must not crash or start anything

        XCTAssertEqual(pipeline.state, .idle)
        XCTAssertEqual(mic.stopCallCount, 0)
        XCTAssertEqual(sysAudio.stopCallCount, 0)
    }

    // MARK: Mute (v1 mix-stage, ADR 0010)

    func test_setSideMute_mic_doesNotStopAdapter() {
        let mic = FakeUpstreamCaptureAdapter()
        let sysAudio = FakeUpstreamCaptureAdapter()
        let pipeline = AudioPipeline(micAdapter: mic, systemAudioAdapter: sysAudio)

        pipeline.consumerAttached()
        pipeline.setSideMute(mic: true)

        // v1: adapter keeps running; mute is mix-stage only
        XCTAssertTrue(mic.isRunning)
        XCTAssertTrue(pipeline.isMicMuted)
    }

    func test_setSideMute_idempotent() {
        let mic = FakeUpstreamCaptureAdapter()
        let sysAudio = FakeUpstreamCaptureAdapter()
        let pipeline = AudioPipeline(micAdapter: mic, systemAudioAdapter: sysAudio)

        pipeline.setSideMute(mic: true)
        pipeline.setSideMute(mic: true) // second call — no-op semantically

        XCTAssertTrue(pipeline.isMicMuted)
    }

    // MARK: State change callback

    func test_stateDidChange_calledOnConsumerAttach() {
        let mic = FakeUpstreamCaptureAdapter()
        let sysAudio = FakeUpstreamCaptureAdapter()
        let pipeline = AudioPipeline(micAdapter: mic, systemAudioAdapter: sysAudio)

        var observedStates: [AudioPipelineState] = []
        pipeline.stateDidChange = { observedStates.append($0) }

        pipeline.consumerAttached()
        pipeline.consumerDetached()

        XCTAssertEqual(observedStates, [.consumerAttached, .idle])
    }

    // MARK: Buffer delivery via fake (Tier-1, ADR 0009)

    func test_fakeAdapter_emitBuffer_callsRegisteredHandler() {
        // Verifies that the fake's emitBuffer helper routes to the installed handler.
        let adapter = FakeUpstreamCaptureAdapter()
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        buffer.frameLength = 512

        var received: AVAudioPCMBuffer?
        adapter.onBuffer = { received = $0 }

        adapter.emitBuffer(buffer)

        XCTAssertNotNil(received)
        XCTAssertEqual(received?.format.sampleRate, 48_000)
        XCTAssertEqual(received?.format.channelCount, 2)
        XCTAssertEqual(received?.frameLength, 512)
    }

    func test_fakeAdapter_emitBuffer_beforeHandlerInstalled_doesNotCrash() {
        // Emitting a buffer before any handler is installed must not crash.
        let adapter = FakeUpstreamCaptureAdapter()
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        buffer.frameLength = 512

        // No handler installed — should silently drop the buffer.
        adapter.emitBuffer(buffer)
        XCTAssertNil(adapter.onBuffer)
    }

    @available(macOS 14.2, *)
    func test_systemAudioAdapter_conformsToUpstreamCaptureAdapter() {
        // Compile-time check: SystemAudioAdapter must satisfy the protocol.
        // This test fails to compile if the conformance is missing.
        let _: any UpstreamCaptureAdapter = SystemAudioAdapter()
    }

    @available(macOS 14.2, *)
    func test_systemAudioAdapter_isNotRunning_afterInit() {
        let adapter = SystemAudioAdapter()
        XCTAssertFalse(adapter.isRunning)
    }

    @available(macOS 14.2, *)
    func test_systemAudioAdapter_stop_whenNotRunning_isNoOp() {
        // stop() on a stopped adapter must not crash.
        let adapter = SystemAudioAdapter()
        adapter.stop()
        XCTAssertFalse(adapter.isRunning)
    }

    @available(macOS 14.2, *)
    func test_systemAudioAdapter_onBuffer_canBeSet() {
        let adapter = SystemAudioAdapter()
        var called = false
        adapter.onBuffer = { _ in called = true }
        XCTAssertFalse(called) // just verifies the property setter doesn't crash
    }

    // MARK: - MicAdapter Tier-1 compile/state tests (ADR 0009)

    func test_micAdapter_conformsToUpstreamCaptureAdapter() {
        // Compile-time check: MicAdapter must satisfy the UpstreamCaptureAdapter protocol.
        // This test fails to compile if the conformance is missing.
        let _: any UpstreamCaptureAdapter = MicAdapter()
    }

    func test_micAdapter_isNotRunning_afterInit() {
        let adapter = MicAdapter()
        XCTAssertFalse(adapter.isRunning)
    }

    func test_micAdapter_stop_whenNotRunning_isNoOp() {
        // stop() on a stopped adapter must not crash.
        let adapter = MicAdapter()
        adapter.stop()
        XCTAssertFalse(adapter.isRunning)
    }

    func test_micAdapter_onBuffer_canBeSet() {
        let adapter = MicAdapter()
        var called = false
        adapter.onBuffer = { _ in called = true }
        XCTAssertFalse(called) // just verifies the property setter doesn't crash
    }

    func test_pipeline_installsBufferHandlerOnSystemAudioAdapter_beforeStart() {
        // AudioPipeline must install onBuffer on systemAudioAdapter so that
        // a fake emitting buffers can drive the pipeline's mix stage.
        let mic = FakeUpstreamCaptureAdapter()
        let sysAudio = FakeUpstreamCaptureAdapter()
        let pipeline = AudioPipeline(micAdapter: mic, systemAudioAdapter: sysAudio)

        // The pipeline should install its buffer handler during init or consumerAttached.
        // After consumerAttached, emitting a buffer through the fake should reach the pipeline.
        var receivedBuffers: [AVAudioPCMBuffer] = []
        pipeline.onSystemAudioBuffer = { receivedBuffers.append($0) }

        pipeline.consumerAttached()

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        buffer.frameLength = 512
        sysAudio.emitBuffer(buffer)

        XCTAssertEqual(receivedBuffers.count, 1)
        XCTAssertEqual(receivedBuffers.first?.frameLength, 512)
    }

    func test_pipeline_installsBufferHandlerOnMicAdapter_beforeStart() {
        let mic = FakeUpstreamCaptureAdapter()
        let sysAudio = FakeUpstreamCaptureAdapter()
        let pipeline = AudioPipeline(micAdapter: mic, systemAudioAdapter: sysAudio)

        var receivedBuffers: [AVAudioPCMBuffer] = []
        pipeline.onMicBuffer = { receivedBuffers.append($0) }

        pipeline.consumerAttached()

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        buffer.frameLength = 512
        mic.emitBuffer(buffer)

        XCTAssertEqual(receivedBuffers.count, 1)
    }

    // MARK: - Mix stage (audio-engine-005, ADR 0010)

    // Helper: make a non-interleaved float32 stereo buffer filled with a constant value.
    private func makeStereoBuffer(frameCount: Int, value: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buf.frameLength = AVAudioFrameCount(frameCount)
        guard let data = buf.floatChannelData else { return buf }
        for ch in 0..<2 {
            for i in 0..<frameCount {
                data[ch][i] = value
            }
        }
        return buf
    }

    /// AC1: With both sides delivering known buffers, mix output equals their sample-wise sum.
    func test_mix_bothSides_outputIsSum() {
        let mic = FakeUpstreamCaptureAdapter()
        let sysAudio = FakeUpstreamCaptureAdapter()
        let pipeline = AudioPipeline(micAdapter: mic, systemAudioAdapter: sysAudio)
        pipeline.consumerAttached()

        let frameCount = 512
        mic.emitBuffer(makeStereoBuffer(frameCount: frameCount, value: 0.3))
        sysAudio.emitBuffer(makeStereoBuffer(frameCount: frameCount, value: 0.4))

        let mixed = pipeline.mix(frameCount: frameCount)

        // Expect 2 channels * 512 frames = 1024 interleaved samples (L,R,L,R,...) or
        // non-interleaved: 512 per channel, 1024 total. Either way sum = 0.3 + 0.4 = 0.7.
        XCTAssertFalse(mixed.isEmpty, "mix() must return samples")
        for sample in mixed {
            XCTAssertEqual(sample, 0.7, accuracy: 1e-5)
        }
    }

    /// AC2: With mic muted, output equals system-audio buffer only.
    func test_mix_micMuted_outputIsSystemAudioOnly() {
        let mic = FakeUpstreamCaptureAdapter()
        let sysAudio = FakeUpstreamCaptureAdapter()
        let pipeline = AudioPipeline(micAdapter: mic, systemAudioAdapter: sysAudio)
        pipeline.consumerAttached()
        pipeline.setSideMute(mic: true)

        let frameCount = 256
        mic.emitBuffer(makeStereoBuffer(frameCount: frameCount, value: 0.9))
        sysAudio.emitBuffer(makeStereoBuffer(frameCount: frameCount, value: 0.5))

        let mixed = pipeline.mix(frameCount: frameCount)

        XCTAssertFalse(mixed.isEmpty)
        for sample in mixed {
            XCTAssertEqual(sample, 0.5, accuracy: 1e-5)
        }
    }

    /// AC3: With system-audio muted, output equals mic buffer only.
    func test_mix_systemAudioMuted_outputIsMicOnly() {
        let mic = FakeUpstreamCaptureAdapter()
        let sysAudio = FakeUpstreamCaptureAdapter()
        let pipeline = AudioPipeline(micAdapter: mic, systemAudioAdapter: sysAudio)
        pipeline.consumerAttached()
        pipeline.setSideMute(systemAudio: true)

        let frameCount = 256
        mic.emitBuffer(makeStereoBuffer(frameCount: frameCount, value: 0.6))
        sysAudio.emitBuffer(makeStereoBuffer(frameCount: frameCount, value: 0.2))

        let mixed = pipeline.mix(frameCount: frameCount)

        XCTAssertFalse(mixed.isEmpty)
        for sample in mixed {
            XCTAssertEqual(sample, 0.6, accuracy: 1e-5)
        }
    }

    /// AC4: With both sides muted, output is all-zeros.
    func test_mix_bothMuted_outputIsAllZeros() {
        let mic = FakeUpstreamCaptureAdapter()
        let sysAudio = FakeUpstreamCaptureAdapter()
        let pipeline = AudioPipeline(micAdapter: mic, systemAudioAdapter: sysAudio)
        pipeline.consumerAttached()
        pipeline.setSideMute(mic: true, systemAudio: true)

        let frameCount = 128
        mic.emitBuffer(makeStereoBuffer(frameCount: frameCount, value: 1.0))
        sysAudio.emitBuffer(makeStereoBuffer(frameCount: frameCount, value: 1.0))

        let mixed = pipeline.mix(frameCount: frameCount)

        XCTAssertFalse(mixed.isEmpty)
        for sample in mixed {
            XCTAssertEqual(sample, 0.0, accuracy: 1e-5)
        }
    }

    /// AC5: mix() returns silence (zeros) for a side that has not yet delivered a buffer.
    func test_mix_oneSideAbsent_treatsAsSilence() {
        let mic = FakeUpstreamCaptureAdapter()
        let sysAudio = FakeUpstreamCaptureAdapter()
        let pipeline = AudioPipeline(micAdapter: mic, systemAudioAdapter: sysAudio)
        pipeline.consumerAttached()

        let frameCount = 64
        // Only mic side delivers; system audio has not produced a buffer yet.
        mic.emitBuffer(makeStereoBuffer(frameCount: frameCount, value: 0.5))
        // sysAudio emits nothing

        let mixed = pipeline.mix(frameCount: frameCount)

        XCTAssertFalse(mixed.isEmpty)
        for sample in mixed {
            // mic(0.5) + sysaudio(silent=0.0) = 0.5
            XCTAssertEqual(sample, 0.5, accuracy: 1e-5)
        }
    }
}
