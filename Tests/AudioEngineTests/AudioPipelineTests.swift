import XCTest
@testable import AudioEngine

// MARK: - Fake adapter (Tier 1, ADR 0009)

/// A controllable fake that records `start()` / `stop()` calls for assertion.
final class FakeUpstreamCaptureAdapter: UpstreamCaptureAdapter, @unchecked Sendable {
    private(set) var startCallCount: Int = 0
    private(set) var stopCallCount: Int = 0
    private(set) var isRunning: Bool = false

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
}
