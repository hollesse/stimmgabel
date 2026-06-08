import XCTest
import AVFAudio
@testable import AudioEngine

// MARK: - Fake XPC stub (ADR 0009, Tier 1)

/// In-process fake for `DriverIPCConnection`.
///
/// Records `writeSamples` calls and allows tests to simulate consumer-active signals
/// by calling `simulateConsumerActive(_:)`.
final class FakeDriverIPCConnection: DriverIPCConnection, @unchecked Sendable {

    // Recorded calls
    private(set) var writeSamplesCalls: [(data: Data, frameCount: UInt32)] = []

    // DriverIPCConnection
    var onConsumerActiveChanged: ((Bool) -> Void)?

    func writeSamples(_ data: Data, frameCount: UInt32) {
        writeSamplesCalls.append((data, frameCount))
    }

    /// Test helper: fire the consumer-active handler as if the driver sent the signal.
    func simulateConsumerActive(_ active: Bool) {
        onConsumerActiveChanged?(active)
    }
}

// MARK: - Tests

final class DriverOutputAdapterTests: XCTestCase {

    // Helper: build a pipeline with a fake system-audio adapter.
    private func makePipeline() -> (pipeline: AudioPipeline, sysAudio: FakeUpstreamCaptureAdapter) {
        let sysAudio = FakeUpstreamCaptureAdapter()
        let pipeline = AudioPipeline(systemAudioAdapter: sysAudio)
        return (pipeline, sysAudio)
    }

    /// Synchronously drain the adapter's internal queue via a barrier block so that
    /// any async work dispatched before this call has completed.
    private func drainAdapterQueue(_ adapter: DriverOutputAdapter) {
        adapter.syncBarrier()
    }

    // MARK: - AC: setConsumerActive(true) → consumerAttached() / adapters start

    func test_consumerActive_true_callsConsumerAttachedOnPipeline() {
        let (pipeline, sysAudio) = makePipeline()
        let fakeIPC = FakeDriverIPCConnection()
        let adapter = DriverOutputAdapter(pipeline: pipeline, ipc: fakeIPC)

        fakeIPC.simulateConsumerActive(true)
        drainAdapterQueue(adapter)

        XCTAssertEqual(pipeline.state, .consumerAttached)
        XCTAssertTrue(sysAudio.isRunning)
    }

    // MARK: - AC: setConsumerActive(false) → consumerDetached() / adapters stop

    func test_consumerActive_false_afterTrue_callsConsumerDetached() {
        let (pipeline, sysAudio) = makePipeline()
        let fakeIPC = FakeDriverIPCConnection()
        let adapter = DriverOutputAdapter(pipeline: pipeline, ipc: fakeIPC)

        fakeIPC.simulateConsumerActive(true)
        drainAdapterQueue(adapter)

        fakeIPC.simulateConsumerActive(false)
        drainAdapterQueue(adapter)

        XCTAssertEqual(pipeline.state, .idle)
        XCTAssertFalse(sysAudio.isRunning)
    }

    // MARK: - AC: duplicate signals are idempotent

    func test_consumerActive_trueAgain_isIdempotent() {
        let (pipeline, sysAudio) = makePipeline()
        let fakeIPC = FakeDriverIPCConnection()
        let adapter = DriverOutputAdapter(pipeline: pipeline, ipc: fakeIPC)

        fakeIPC.simulateConsumerActive(true)
        fakeIPC.simulateConsumerActive(true) // second true must be a no-op
        drainAdapterQueue(adapter)

        // Adapters started exactly once despite two signals.
        XCTAssertEqual(sysAudio.startCallCount, 1)
        _ = pipeline // keep alive
    }

    func test_consumerActive_falseAgain_isIdempotent() {
        let (pipeline, _) = makePipeline()
        let fakeIPC = FakeDriverIPCConnection()
        let adapter = DriverOutputAdapter(pipeline: pipeline, ipc: fakeIPC)

        // Already idle — false must not crash.
        fakeIPC.simulateConsumerActive(false)
        drainAdapterQueue(adapter)

        XCTAssertEqual(pipeline.state, .idle)
    }

    // MARK: - AC: emitBuffer while active produces writeSamples calls (IOProc-driven model)

    func test_consumerActive_true_emitBuffer_producesWriteSamplesCall() {
        let (pipeline, sysAudio) = makePipeline()
        let fakeIPC = FakeDriverIPCConnection()
        let adapter = DriverOutputAdapter(pipeline: pipeline, ipc: fakeIPC)

        fakeIPC.simulateConsumerActive(true)
        drainAdapterQueue(adapter)

        sysAudio.emitBuffer(makeStereoBuffer(frameCount: 512, value: 0.5))

        XCTAssertGreaterThan(fakeIPC.writeSamplesCalls.count, 0,
            "writeSamples should be called immediately when system audio buffer arrives")
    }

    func test_consumerActive_false_emitBuffer_doesNotWriteSamples() {
        let (pipeline, sysAudio) = makePipeline()
        let fakeIPC = FakeDriverIPCConnection()
        let adapter = DriverOutputAdapter(pipeline: pipeline, ipc: fakeIPC)

        // Active then inactive.
        fakeIPC.simulateConsumerActive(true)
        drainAdapterQueue(adapter)
        fakeIPC.simulateConsumerActive(false)
        drainAdapterQueue(adapter)

        let countAtStop = fakeIPC.writeSamplesCalls.count

        // Emit after consumer detached — must not trigger another write.
        sysAudio.emitBuffer(makeStereoBuffer(frameCount: 512, value: 0.9))

        XCTAssertEqual(fakeIPC.writeSamplesCalls.count, countAtStop,
            "writeSamples must not be called after consumer detaches")
        _ = adapter
    }

    // MARK: - AC: writeSamples payload has correct frame count

    func test_writeSamples_frameCountMatchesBufferFrameLength() {
        let (pipeline, sysAudio) = makePipeline()
        let fakeIPC = FakeDriverIPCConnection()
        let adapter = DriverOutputAdapter(pipeline: pipeline, ipc: fakeIPC)

        fakeIPC.simulateConsumerActive(true)
        drainAdapterQueue(adapter)

        let frames = 512
        sysAudio.emitBuffer(makeStereoBuffer(frameCount: frames, value: 0.3))

        guard let first = fakeIPC.writeSamplesCalls.first else {
            XCTFail("Expected a writeSamples call after emitBuffer"); return
        }
        XCTAssertEqual(first.frameCount, UInt32(frames))
        let expectedBytes = frames * 2 * MemoryLayout<Float>.size
        XCTAssertEqual(first.data.count, expectedBytes)
        _ = adapter
    }

    private func makeStereoBuffer(frameCount: Int, value: Float) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: 48_000, channels: 2, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frameCount))!
        buf.frameLength = AVAudioFrameCount(frameCount)
        if let ch0 = buf.floatChannelData?[0], let ch1 = buf.floatChannelData?[1] {
            for i in 0..<frameCount { ch0[i] = value; ch1[i] = value }
        }
        return buf
    }
}
