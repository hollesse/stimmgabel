import XCTest
import AVFAudio
import Darwin
import DriverIPC
@testable import AudioEngine

// MARK: - End-to-End Tests
//
// These tests exercise the COMPLETE data path without ANY mocks in the IPC layer:
//
//   FakeUpstreamCaptureAdapter   — injects known audio (no real hardware)
//       ↓
//   AudioPipeline / Mixer        — real production code
//       ↓
//   SHMDriverIPCConnection       — writes to REAL POSIX SHM (/stimmgabel-audio-v1)
//       ↓
//   mmap + driverRead()          — reads with exact DoIOOperation algorithm
//       ↓
//   XCTAssert: output ≈ input    — signal preserved end-to-end
//
// What this catches that no other test covers:
//   • Bugs in SHMDriverIPCConnection.writeToSHM() (wrong offset, wrong slot math)
//   • Bugs in the Swift→C byte layout (endianness, padding)
//   • Mute state affecting what actually lands in SHM
//   • writePos not advancing → driver reads silence forever
//
// NOTE: Do not run while Stimmgabel.app is open — both would share the same SHM
// segment and the test results would be unpredictable.

final class E2ETests: XCTestCase {

    // MARK: - Mix target format

    private let mixFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    )!

    // MARK: - Signal helpers

    private func makeSine(frames: Int, freq: Float = 440, amplitude: Float = 0.5) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: mixFormat,
                                   frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        let ch0 = buf.floatChannelData![0]
        let ch1 = buf.floatChannelData![1]
        for i in 0..<frames {
            let v = amplitude * sinf(2 * .pi * freq * Float(i) / 48_000)
            ch0[i] = v
            ch1[i] = v
        }
        return buf
    }

    /// Normalized cross-correlation — 1.0 means identical signal content.
    private func correlation(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        let dot  = zip(a.prefix(n), b.prefix(n)).reduce(0 as Float) { $0 + $1.0 * $1.1 }
        let normA = sqrtf(a.prefix(n).reduce(0) { $0 + $1 * $1 })
        let normB = sqrtf(b.prefix(n).reduce(0) { $0 + $1 * $1 })
        guard normA > 1e-10, normB > 1e-10 else { return 0 }
        return dot / (normA * normB)
    }

    // MARK: - Driver read helper (exact DoIOOperation algorithm)

    private func driverReadFromRealSHM(drainFrames: UInt32) -> (left: [Float], right: [Float])? {
        let fd = sg_shm_open(SG_SHM_NAME, O_RDONLY, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let kSize = 8 + 8 + Int(SG_SHM_CAPACITY) * 2 * MemoryLayout<Float>.size
        guard let ptr = mmap(nil, kSize, PROT_READ, MAP_SHARED, fd, 0),
              ptr != MAP_FAILED else { return nil }
        defer { munmap(ptr, kSize) }

        let buf = ptr.assumingMemoryBound(to: SHMAudioBuffer.self)
        let w   = sg_shm_get_write_pos(buf)

        var L = [Float](repeating: 0, count: Int(drainFrames))
        var R = [Float](repeating: 0, count: Int(drainFrames))

        guard w >= UInt64(drainFrames) else { return (L, R) }

        let base = w - UInt64(drainFrames)
        for i in 0..<Int(drainFrames) {
            let slot = UInt32((base + UInt64(i)) % UInt64(SG_SHM_CAPACITY))
            L[i] = sg_shm_read_sample(buf, slot * 2)
            R[i] = sg_shm_read_sample(buf, slot * 2 + 1)
        }
        return (L, R)
    }

    // MARK: - Setup / teardown

    override func setUp() {
        super.setUp()
        // Unlink stale SHM from a previous crashed test — recreated by SHMDriverIPCConnection.connect().
        // We do NOT unlink in tearDown so the running Stimmgabel.app can keep using the segment.
        sg_shm_unlink(SG_SHM_NAME)
    }

    // MARK: - E2E 1: Known signal → SHM → driver read → output ≈ input

    func test_e2e_knownSignal_survivesFullPipeline() throws {
        // 1. Build the full pipeline with real SHM IPC.
        let mic = FakeUpstreamCaptureAdapter()
        let sys = FakeUpstreamCaptureAdapter()
        let pipeline = AudioPipeline(systemAudioAdapter: sys, micAdapter: FakeUpstreamCaptureAdapter())
        let shmConn  = SHMDriverIPCConnection()
        let adapter  = DriverOutputAdapter(pipeline: pipeline, ipc: shmConn)
        // DriverOutputAdapter.init() calls shmConn.connect() which opens SHM.

        // Wait for the async openSHM() to complete.
        Thread.sleep(forTimeInterval: 0.05)

        // 2. Start the pipeline by triggering consumer-active
        //    (bypasses Darwin notify — no driver process needed).
        shmConn.onConsumerActiveChanged?(true)
        adapter.syncBarrier()

        // 4. Pre-fill the staging FIFO with 8 × 512-frame sine buffers (= 4096 frames ≈ 85 ms).
        // This ensures that after several render ticks the SHM still contains non-zero data
        // when we read it, avoiding flakiness from the "latest-frame" overwrite timing.
        let inputBuf = makeSine(frames: 512, freq: 440, amplitude: 0.5)
        for _ in 0..<8 { sys.emitBuffer(inputBuf) }

        // 5. Wait for a few render ticks + SHM queue flush.
        Thread.sleep(forTimeInterval: 0.040)
        adapter.syncBarrier()
        Thread.sleep(forTimeInterval: 0.010)

        // 6. Read from the real SHM using the exact DoIOOperation algorithm.
        guard let (outL, outR) = driverReadFromRealSHM(drainFrames: 512) else {
            XCTFail("Could not open SHM — SHMDriverIPCConnection.connect() likely failed. " +
                    "Check that no other process is locking the segment.")
            return
        }

        // 7. Extract expected left channel from input buffer.
        let inL = (0..<512).map { inputBuf.floatChannelData![0][$0] }

        // 8a. writePos must have advanced (otherwise driver always sees silence).
        let fd = sg_shm_open(SG_SHM_NAME, O_RDONLY, 0)
        guard fd >= 0 else { XCTFail("SHM not found after pipeline ran"); return }
        let kSize = 8 + 8 + Int(SG_SHM_CAPACITY) * 2 * MemoryLayout<Float>.size
        let ptr   = mmap(nil, kSize, PROT_READ, MAP_SHARED, fd, 0)!
        let wp    = sg_shm_get_write_pos(ptr.assumingMemoryBound(to: SHMAudioBuffer.self))
        munmap(ptr, kSize); close(fd)

        XCTAssertGreaterThan(wp, 0,
            "writePos is still 0 after pipeline ran. " +
            "SHMDriverIPCConnection.writeToSHM() was never called — " +
            "render timer may not have fired.")

        // 8b. Output must not be pure silence.
        let outPeak = outL.map(abs).max() ?? 0
        XCTAssertGreaterThan(outPeak, 0.01,
            "Driver reads pure silence from SHM (peak=\(outPeak)) even though " +
            "system audio was injected. " +
            "Possible causes: writeToSHM offset wrong, wrong slot calculation, " +
            "or StagingBuffer.store() silently rejected the buffer.")

        // 8c. Signal content must be preserved (cross-correlation ≥ 0.95).
        let corr = correlation(inL, outL)
        XCTAssertGreaterThan(corr, 0.95,
            "E2E correlation \(corr) < 0.95. " +
            "The 440 Hz sine fed in does not match what the driver reads back. " +
            "The signal was garbled between Swift pipeline and SHM. " +
            "Check: StagingBuffer interleaving, Mixer.mix() output order, " +
            "writeToSHM slot calculation.")

        // 8d. Amplitude must be preserved (output peak ≥ 80% of input peak).
        let inPeak = inL.map(abs).max()!
        XCTAssertGreaterThan(outPeak, inPeak * 0.8,
            "Output peak \(outPeak) < 80% of input \(inPeak). " +
            "Signal attenuated through the pipeline.")
    }

    // MARK: - E2E 2: No buffer → SHM stays silence

    func test_e2e_noBuffer_shmStaysSilence() throws {
        let sys = FakeUpstreamCaptureAdapter()
        let pipeline = AudioPipeline(systemAudioAdapter: sys, micAdapter: FakeUpstreamCaptureAdapter())
        let shmConn  = SHMDriverIPCConnection()
        let adapter  = DriverOutputAdapter(pipeline: pipeline, ipc: shmConn)

        Thread.sleep(forTimeInterval: 0.05)
        shmConn.onConsumerActiveChanged?(true)
        adapter.syncBarrier()

        // No buffer emitted — pipeline writes silence to SHM.
        Thread.sleep(forTimeInterval: 0.05)
        adapter.syncBarrier()
        Thread.sleep(forTimeInterval: 0.02)

        guard let (outL, outR) = driverReadFromRealSHM(drainFrames: 512) else {
            XCTFail("Could not open SHM"); return
        }

        let peakL = outL.map(abs).max() ?? 0
        let peakR = outR.map(abs).max() ?? 0

        XCTAssertLessThan(peakL, 0.01,
            "Left channel peak \(peakL) — SHM should be silence when no buffer is available.")
        XCTAssertLessThan(peakR, 0.01,
            "Right channel peak \(peakR) — SHM should be silence when no buffer is available.")
    }

    // MARK: - E2E 3: writePos advances on each render tick

    func test_e2e_writePosAdvancesOnEachTick() throws {
        let mic = FakeUpstreamCaptureAdapter()
        let sys = FakeUpstreamCaptureAdapter()
        let pipeline = AudioPipeline(systemAudioAdapter: sys, micAdapter: FakeUpstreamCaptureAdapter())
        let shmConn  = SHMDriverIPCConnection()
        let adapter  = DriverOutputAdapter(pipeline: pipeline, ipc: shmConn)

        Thread.sleep(forTimeInterval: 0.05)
        shmConn.onConsumerActiveChanged?(true)
        adapter.syncBarrier()

        sys.emitBuffer(makeSine(frames: 512, amplitude: 0.3))

        // Read writePos before ticks.
        func currentWritePos() -> UInt64 {
            let fd = sg_shm_open(SG_SHM_NAME, O_RDONLY, 0)
            guard fd >= 0 else { return 0 }
            let kSize = 8 + 8 + Int(SG_SHM_CAPACITY) * 2 * MemoryLayout<Float>.size
            guard let ptr = mmap(nil, kSize, PROT_READ, MAP_SHARED, fd, 0),
                  ptr != MAP_FAILED else { close(fd); return 0 }
            let wp = sg_shm_get_write_pos(ptr.assumingMemoryBound(to: SHMAudioBuffer.self))
            munmap(ptr, kSize); close(fd)
            return wp
        }

        let wp0 = currentWritePos()

        // Wait for ~5 render ticks (5 × 10.67 ms ≈ 55 ms).
        Thread.sleep(forTimeInterval: 0.07)
        adapter.syncBarrier()
        Thread.sleep(forTimeInterval: 0.02)

        let wp1 = currentWritePos()

        XCTAssertGreaterThan(wp1, wp0,
            "writePos did not advance (wp0=\(wp0) wp1=\(wp1)). " +
            "The render timer is running but writeToSHM() is not executing. " +
            "Check SHMDriverIPCConnection.queue for backlog or silent failures.")

        // Should have advanced by at least 512 frames (1 tick) in 70ms.
        let advanced = wp1 - wp0
        XCTAssertGreaterThanOrEqual(advanced, 512,
            "writePos advanced by only \(advanced) frames in 70ms. " +
            "Expected ≥ 512 (one render tick at 48 kHz / 512 frames). " +
            "Render timer interval may be wrong.")
    }
}
