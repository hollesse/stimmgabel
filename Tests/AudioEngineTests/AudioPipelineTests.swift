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
}
