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

    // Helper: build a pipeline with fake adapters.
    private func makePipeline() -> (pipeline: AudioPipeline, mic: FakeUpstreamCaptureAdapter, sysAudio: FakeUpstreamCaptureAdapter) {
        let mic = FakeUpstreamCaptureAdapter()
        let sysAudio = FakeUpstreamCaptureAdapter()
        let pipeline = AudioPipeline(micAdapter: mic, systemAudioAdapter: sysAudio)
        return (pipeline, mic, sysAudio)
    }

    /// Synchronously drain the adapter's internal queue via a barrier block so that
    /// any async work dispatched before this call has completed.
    private func drainAdapterQueue(_ adapter: DriverOutputAdapter) {
        adapter.syncBarrier()
    }

    // MARK: - AC: setConsumerActive(true) → consumerAttached() / adapters start

    func test_consumerActive_true_callsConsumerAttachedOnPipeline() {
        let (pipeline, mic, sysAudio) = makePipeline()
        let fakeIPC = FakeDriverIPCConnection()
        let adapter = DriverOutputAdapter(pipeline: pipeline, ipc: fakeIPC)

        fakeIPC.simulateConsumerActive(true)
        drainAdapterQueue(adapter)

        XCTAssertEqual(pipeline.state, .consumerAttached)
        XCTAssertTrue(mic.isRunning)
        XCTAssertTrue(sysAudio.isRunning)
    }

    // MARK: - AC: setConsumerActive(false) → consumerDetached() / adapters stop

    func test_consumerActive_false_afterTrue_callsConsumerDetached() {
        let (pipeline, mic, sysAudio) = makePipeline()
        let fakeIPC = FakeDriverIPCConnection()
        let adapter = DriverOutputAdapter(pipeline: pipeline, ipc: fakeIPC)

        fakeIPC.simulateConsumerActive(true)
        drainAdapterQueue(adapter)

        fakeIPC.simulateConsumerActive(false)
        drainAdapterQueue(adapter)

        XCTAssertEqual(pipeline.state, .idle)
        XCTAssertFalse(mic.isRunning)
        XCTAssertFalse(sysAudio.isRunning)
    }

    // MARK: - AC: duplicate signals are idempotent

    func test_consumerActive_trueAgain_isIdempotent() {
        let (pipeline, mic, sysAudio) = makePipeline()
        let fakeIPC = FakeDriverIPCConnection()
        let adapter = DriverOutputAdapter(pipeline: pipeline, ipc: fakeIPC)

        fakeIPC.simulateConsumerActive(true)
        fakeIPC.simulateConsumerActive(true) // second true must be a no-op
        drainAdapterQueue(adapter)

        // Adapters started exactly once despite two signals.
        XCTAssertEqual(mic.startCallCount, 1)
        XCTAssertEqual(sysAudio.startCallCount, 1)
        _ = pipeline // keep alive
    }

    func test_consumerActive_falseAgain_isIdempotent() {
        let (pipeline, _, _) = makePipeline()
        let fakeIPC = FakeDriverIPCConnection()
        let adapter = DriverOutputAdapter(pipeline: pipeline, ipc: fakeIPC)

        // Already idle — false must not crash.
        fakeIPC.simulateConsumerActive(false)
        drainAdapterQueue(adapter)

        XCTAssertEqual(pipeline.state, .idle)
    }

    // MARK: - AC: render timer produces writeSamples calls

    func test_consumerActive_true_producesWriteSamplesCalls() {
        let (pipeline, _, _) = makePipeline()
        let fakeIPC = FakeDriverIPCConnection()
        let adapter = DriverOutputAdapter(pipeline: pipeline, ipc: fakeIPC)

        fakeIPC.simulateConsumerActive(true)
        drainAdapterQueue(adapter)

        // Wait long enough for at least 2 render ticks (each ~10.67 ms → wait 100 ms).
        Thread.sleep(forTimeInterval: 0.1)
        drainAdapterQueue(adapter)

        XCTAssertGreaterThan(fakeIPC.writeSamplesCalls.count, 0, "writeSamples should be called while consumer is active")
    }

    func test_consumerActive_false_stopsWriteSamplesCalls() {
        let (pipeline, _, _) = makePipeline()
        let fakeIPC = FakeDriverIPCConnection()
        let adapter = DriverOutputAdapter(pipeline: pipeline, ipc: fakeIPC)

        fakeIPC.simulateConsumerActive(true)
        drainAdapterQueue(adapter)

        // Wait for some ticks.
        Thread.sleep(forTimeInterval: 0.1)
        drainAdapterQueue(adapter)

        let countBefore = fakeIPC.writeSamplesCalls.count
        XCTAssertGreaterThan(countBefore, 0)

        fakeIPC.simulateConsumerActive(false)
        drainAdapterQueue(adapter)

        // Let any in-flight ticks drain.
        Thread.sleep(forTimeInterval: 0.05)
        drainAdapterQueue(adapter)

        let countAfterStop = fakeIPC.writeSamplesCalls.count

        // No more ticks should fire — wait another interval.
        Thread.sleep(forTimeInterval: 0.05)
        drainAdapterQueue(adapter)

        XCTAssertEqual(fakeIPC.writeSamplesCalls.count, countAfterStop, "timer must have stopped after consumer detached")
    }

    // MARK: - AC: writeSamples payload has correct frame count

    func test_writeSamples_frameCountMatchesRenderPeriod() {
        let (pipeline, _, _) = makePipeline()
        let fakeIPC = FakeDriverIPCConnection()
        let adapter = DriverOutputAdapter(pipeline: pipeline, ipc: fakeIPC)

        fakeIPC.simulateConsumerActive(true)
        drainAdapterQueue(adapter)

        Thread.sleep(forTimeInterval: 0.1)
        drainAdapterQueue(adapter)

        guard let first = fakeIPC.writeSamplesCalls.first else {
            XCTFail("Expected at least one writeSamples call")
            return
        }

        XCTAssertEqual(first.frameCount, UInt32(DriverOutputAdapter.renderFrameCount))
        // interleaved stereo: frameCount * 2 channels * 4 bytes/sample
        let expectedBytes = DriverOutputAdapter.renderFrameCount * 2 * MemoryLayout<Float>.size
        XCTAssertEqual(first.data.count, expectedBytes)
    }
}
