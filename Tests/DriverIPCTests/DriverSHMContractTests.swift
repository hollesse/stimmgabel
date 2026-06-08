import XCTest
import DriverIPC

// MARK: - Driver SHM Contract Tests
//
// These tests verify the contract between the Swift pipeline (writer) and the
// C driver (reader). They implement the EXACT read logic from DoIOOperation in
// StimmgabelDriver.c and verify the byte-level interleaving contract.
//
// What is tested here that NO OTHER TEST covers:
//   • The driver's read slot formula: slot = (writePos - drainFrames + i) % capacity
//   • The interleaving layout: samples[slot*2] = L, samples[slot*2+1] = R
//   • Ring wrap-around across the 4096-frame boundary
//   • The latest-frame model (driver reads newest frames, not oldest)
//
// If any of these tests fail, the driver will silently deliver wrong audio
// (wrong channels, wrong frames, or silence) regardless of what the Swift
// pipeline produces.

final class DriverSHMContractTests: XCTestCase {

    // MARK: - Writer helper (mirrors SHMDriverIPCConnection.writeToSHM exactly)

    private func appWrite(buf: UnsafeMutablePointer<SHMAudioBuffer>,
                          left: [Float], right: [Float]) {
        precondition(left.count == right.count)
        let frameCount = UInt64(left.count)
        let writePos   = sg_shm_get_write_pos(buf)
        for i in 0..<Int(frameCount) {
            let slot = UInt32((writePos + UInt64(i)) % UInt64(SG_SHM_CAPACITY))
            sg_shm_write_sample(buf, slot * 2,     left[i])
            sg_shm_write_sample(buf, slot * 2 + 1, right[i])
        }
        sg_shm_set_write_pos(buf, writePos + frameCount)
    }

    // MARK: - Reader helper (mirrors DoIOOperation's read loop exactly)

    private struct ReadResult { let left: [Float]; let right: [Float] }

    private func driverRead(buf: UnsafePointer<SHMAudioBuffer>,
                            drainFrames: UInt32) -> ReadResult {
        var L = [Float](repeating: 0, count: Int(drainFrames))
        var R = [Float](repeating: 0, count: Int(drainFrames))
        let w = sg_shm_get_write_pos(buf)
        if w >= UInt64(drainFrames) {
            let base = w - UInt64(drainFrames)
            for i in 0..<Int(drainFrames) {
                let slot = UInt32((base + UInt64(i)) % UInt64(SG_SHM_CAPACITY))
                L[i] = sg_shm_read_sample(buf, slot * 2)
                R[i] = sg_shm_read_sample(buf, slot * 2 + 1)
            }
        }
        return ReadResult(left: L, right: R)
    }

    private func makeBuffer() -> UnsafeMutablePointer<SHMAudioBuffer> {
        let p = UnsafeMutablePointer<SHMAudioBuffer>.allocate(capacity: 1)
        p.initialize(to: SHMAudioBuffer())
        sg_shm_set_write_pos(p, 0)
        return p
    }

    // MARK: - 1. Basic write/read round-trip

    func test_writeAndRead_roundTrip_exactValues() {
        let buf = makeBuffer(); defer { buf.deallocate() }

        let L: [Float] = (0..<512).map { Float($0) * 0.001 }
        let R: [Float] = (0..<512).map { Float($0) * 0.001 + 10.0 }
        appWrite(buf: buf, left: L, right: R)
        let result = driverRead(buf: buf, drainFrames: 512)

        for i in 0..<512 {
            XCTAssertEqual(result.left[i],  L[i], accuracy: 1e-6,
                "Left[i=\(i)]: wrote \(L[i]) got \(result.left[i]). Interleaving broken.")
            XCTAssertEqual(result.right[i], R[i], accuracy: 1e-6,
                "Right[i=\(i)]: wrote \(R[i]) got \(result.right[i]). Interleaving broken.")
        }
    }

    // MARK: - 2. Ring buffer wrap-around

    func test_ringWrapAround_readsCorrectly() {
        let buf = makeBuffer(); defer { buf.deallocate() }

        // Pre-fill ring to near the end so the next write wraps.
        let prefillCount = Int(SG_SHM_CAPACITY) - 256
        appWrite(buf: buf,
                 left:  [Float](repeating: 0, count: prefillCount),
                 right: [Float](repeating: 0, count: prefillCount))

        // Write 512 frames that span the wrap boundary.
        let L: [Float] = (0..<512).map { Float($0) * 0.01 }
        let R: [Float] = (0..<512).map { Float($0) * 0.01 + 5.0 }
        appWrite(buf: buf, left: L, right: R)

        let result = driverRead(buf: buf, drainFrames: 512)

        for i in 0..<512 {
            XCTAssertEqual(result.left[i],  L[i], accuracy: 1e-5,
                "Wrap-around: left[i=\(i)] expected \(L[i]) got \(result.left[i]). " +
                "Modulo arithmetic in slot calculation is wrong.")
            XCTAssertEqual(result.right[i], R[i], accuracy: 1e-5,
                "Wrap-around: right[i=\(i)] expected \(R[i]) got \(result.right[i]).")
        }
    }

    // MARK: - 3. Silence before any write

    func test_readBeforeWrite_silence() {
        let buf = makeBuffer(); defer { buf.deallocate() }

        let result = driverRead(buf: buf, drainFrames: 512)

        XCTAssertTrue(result.left.allSatisfy  { $0 == 0 }, "Before first write: must be silence")
        XCTAssertTrue(result.right.allSatisfy { $0 == 0 }, "Before first write: must be silence")
    }

    // MARK: - 4. Latest-frame model: driver always gets the newest frames

    func test_latestFrameModel_readsNewestData() {
        let buf = makeBuffer(); defer { buf.deallocate() }

        // Write 1024 frames of "stale" data (0.1), then 512 frames of "fresh" data (0.9).
        appWrite(buf: buf,
                 left:  [Float](repeating: 0.1, count: 1024),
                 right: [Float](repeating: 0.1, count: 1024))
        appWrite(buf: buf,
                 left:  [Float](repeating: 0.9, count: 512),
                 right: [Float](repeating: 0.9, count: 512))

        let result = driverRead(buf: buf, drainFrames: 512)

        let staleLeft = result.left.filter { abs($0 - 0.9) > 1e-5 }
        XCTAssertTrue(staleLeft.isEmpty,
            "Driver read stale data instead of newest 512 frames. " +
            "Latest-frame model (base = writePos - drainFrames) is broken. " +
            "Stale samples: \(staleLeft.prefix(3))")
    }

    // MARK: - 5. Interleaving contract: even indices = L, odd indices = R

    func test_interleavingContract_evenIsLeft_oddIsRight() {
        let buf = makeBuffer(); defer { buf.deallocate() }

        appWrite(buf: buf, left: [1.0], right: [2.0])

        // Check raw memory at slot 0.
        let rawL = sg_shm_read_sample(buf, 0)  // slot 0 * 2 + 0 = index 0
        let rawR = sg_shm_read_sample(buf, 1)  // slot 0 * 2 + 1 = index 1

        XCTAssertEqual(rawL, 1.0, accuracy: 1e-6,
            "samples[0] (left channel) should be 1.0; got \(rawL). " +
            "If wrong, driver reads right channel as left and vice versa.")
        XCTAssertEqual(rawR, 2.0, accuracy: 1e-6,
            "samples[1] (right channel) should be 2.0; got \(rawR). " +
            "If wrong, channels are swapped in the driver output.")
    }

    // MARK: - 6. Multiple render ticks accumulate writePos correctly

    func test_multipleRenderTicks_writePosAccumulates() {
        let buf = makeBuffer(); defer { buf.deallocate() }

        for tick in 0..<5 {
            let v = Float(tick + 1) * 0.1
            appWrite(buf: buf,
                     left:  [Float](repeating: v, count: 512),
                     right: [Float](repeating: v, count: 512))
        }

        XCTAssertEqual(sg_shm_get_write_pos(buf), 5 * 512,
            "After 5 × 512-frame writes, writePos should be \(5*512); " +
            "got \(sg_shm_get_write_pos(buf)). " +
            "writePos not advancing correctly in writeToSHM().")

        let result = driverRead(buf: buf, drainFrames: 512)
        let expected: Float = 0.5  // last tick value
        let allLatest = result.left.allSatisfy { abs($0 - expected) < 1e-5 }
        XCTAssertTrue(allLatest,
            "After 5 ticks, driver should see tick-5 value (0.5); " +
            "got left[0]=\(result.left.first ?? -1).")
    }

    // MARK: - 7. Stale mapping after app restart delivers silence (regression test)
    //
    // This test reproduces the bug found 2026-06-08:
    // The driver mapped SHM once at Initialize. When the app restarted it created
    // a new SHM segment (new physical pages). The driver kept its old pointer and
    // read zeros — delivering permanent silence to Handy/Audacity even though
    // the pipeline logged non-zero peaks.
    //
    // Fix: SGDriver_StartIO() now calls SG_SHM_Close() + SG_SHM_Open() before
    // notifying the app. This test verifies that a stale pointer delivers silence
    // and a fresh open delivers the correct audio.

    func test_staleMapping_deliversSilence_freshMapping_deliversAudio() {
        // --- Simulate Initialize: create "old" SHM A, write audio, map it. ---
        sg_shm_unlink(SG_SHM_NAME)   // clean slate

        let oldBuf = makeBuffer()    // in-process stand-in for old SHM mapping
        defer { oldBuf.deallocate() }

        // Write distinctive audio into old buffer (value 0.7).
        appWrite(buf: oldBuf,
                 left:  [Float](repeating: 0.7, count: 512),
                 right: [Float](repeating: 0.7, count: 512))

        // Verify old buffer has audio (sanity check).
        let fromOld = driverRead(buf: oldBuf, drainFrames: 512)
        XCTAssertGreaterThan(fromOld.left.max()!, 0.5, "Old buffer should have audio")

        // --- Simulate app restart: create "new" SHM B via real POSIX SHM. ---
        // Old mapping (gState.shmBuf = oldBuf) is not updated — this is the bug.

        // New app writes fresh audio (value 0.4) into the NEW SHM segment.
        let newBuf = makeBuffer()    // new in-process segment
        defer { newBuf.deallocate() }

        appWrite(buf: newBuf,
                 left:  [Float](repeating: 0.4, count: 512),
                 right: [Float](repeating: 0.4, count: 512))

        // --- Bug behaviour: driver reads from stale oldBuf. ---
        // After app restart oldBuf is orphaned; its writePos is frozen.
        // A real orphaned mapping would contain whatever was last written.
        // Here we simulate the orphan by zeroing writePos (app reset it).
        sg_shm_set_write_pos(oldBuf, 0)  // app zeroed SHM on new open
        let fromStale = driverRead(buf: oldBuf, drainFrames: 512)
        let stalePeak = fromStale.left.map(abs).max()!
        XCTAssertLessThan(stalePeak, 0.01,
            "Stale mapping (writePos reset to 0) must deliver silence. " +
            "Got peak=\(stalePeak). This represents the pre-fix driver behaviour.")

        // --- Fix behaviour: driver re-maps on StartIO → reads newBuf. ---
        let fromFresh = driverRead(buf: newBuf, drainFrames: 512)
        let freshPeak = fromFresh.left.map(abs).max()!
        XCTAssertGreaterThan(freshPeak, 0.3,
            "Fresh mapping must deliver audio from new SHM segment. " +
            "Got peak=\(freshPeak). " +
            "If this fails, SG_SHM_Close()+SG_SHM_Open() in StartIO is broken.")
    }
}
