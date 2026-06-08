import XCTest
import DriverIPC

// MARK: - DoIOOperation Contract Tests
//
// Verifies the read path that DoIOOperation uses to drain SHM into the float*
// buffer that coreaudiod gives it.
//
// The driver is called TWICE per IO cycle (once per channel for non-interleaved
// stereo).  Each call receives a flat float* (ioMainBuffer) for one channel's
// worth of inIOBufferFrameSize samples.  We fill it with a mono mix (L+R)/2 from
// the SHM ring buffer — same value for both channels.
//
// These tests mirror that algorithm in Swift so we can verify the SHM layout and
// read formula without running the real driver binary.

final class DriverDoIOTests: XCTestCase {

    // MARK: - SHM helpers (same as DriverSHMContractTests)

    private func makeBuffer() -> UnsafeMutablePointer<SHMAudioBuffer> {
        let p = UnsafeMutablePointer<SHMAudioBuffer>.allocate(capacity: 1)
        p.initialize(to: SHMAudioBuffer())
        sg_shm_set_write_pos(p, 0)
        return p
    }

    private func appWrite(buf: UnsafeMutablePointer<SHMAudioBuffer>,
                          left: [Float], right: [Float]) {
        precondition(left.count == right.count)
        let n = UInt64(left.count)
        let wp = sg_shm_get_write_pos(buf)
        for i in 0..<Int(n) {
            let slot = UInt32((wp + UInt64(i)) % UInt64(SG_SHM_CAPACITY))
            sg_shm_write_sample(buf, slot * 2,     left[i])
            sg_shm_write_sample(buf, slot * 2 + 1, right[i])
        }
        sg_shm_set_write_pos(buf, wp + n)
    }

    // MARK: - Mirror of DoIOOperation's read loop (float* mono mix)
    //
    // Returns the output array that DoIOOperation writes into ioMainBuffer.
    // Both the L-channel and R-channel calls produce identical output.

    private func doIO(shm: UnsafePointer<SHMAudioBuffer>,
                      frames: UInt32) -> [Float] {
        var out = [Float](repeating: 0, count: Int(frames))
        let w = sg_shm_get_write_pos(shm)
        if w >= UInt64(frames) {
            let base = w - UInt64(frames)
            for i in 0..<Int(frames) {
                let slot = UInt32((base + UInt64(i)) % UInt64(SG_SHM_CAPACITY))
                out[i] = (sg_shm_read_sample(shm, slot * 2)
                        + sg_shm_read_sample(shm, slot * 2 + 1)) * 0.5
            }
        }
        return out
    }

    // MARK: - 1. Basic round-trip — known signal survives SHM

    func test_monoMix_roundTrip() {
        let buf = makeBuffer(); defer { buf.deallocate() }

        let L: [Float] = (0..<512).map { 0.5 * sinf(2 * .pi * 440 * Float($0) / 48_000) }
        let R: [Float] = (0..<512).map { 0.5 * sinf(2 * .pi * 440 * Float($0) / 48_000) }
        appWrite(buf: buf, left: L, right: R)

        let out = doIO(shm: buf, frames: 512)
        let peak = out.map(abs).max() ?? 0
        XCTAssertGreaterThan(peak, 0.4,
            "mono mix of 440 Hz at amplitude 0.5 should have peak > 0.4; got \(peak)")
    }

    // MARK: - 2. Silence before any write

    func test_silence_when_writePosLessThanFrames() {
        let buf = makeBuffer(); defer { buf.deallocate() }
        let out = doIO(shm: buf, frames: 512)
        XCTAssertTrue(out.allSatisfy { $0 == 0 }, "Must be silence when writePos=0")
    }

    // MARK: - 3. Latest-frame model

    func test_latestFrame_afterMultipleWrites() {
        let buf = makeBuffer(); defer { buf.deallocate() }

        appWrite(buf: buf,
                 left:  [Float](repeating: 0.1, count: 512),
                 right: [Float](repeating: 0.1, count: 512))
        appWrite(buf: buf,
                 left:  [Float](repeating: 0.9, count: 512),
                 right: [Float](repeating: 0.9, count: 512))

        let out = doIO(shm: buf, frames: 512)
        let allFresh = out.allSatisfy { abs($0 - 0.9) < 1e-5 }
        XCTAssertTrue(allFresh,
            "Driver must read the LATEST 512 frames (0.9), not stale ones (0.1). " +
            "Got out[0]=\(out.first ?? -1)")
    }

    // MARK: - 4. Ring wrap-around

    func test_ringWrapAround_signalPreserved() {
        let buf = makeBuffer(); defer { buf.deallocate() }

        let prefill = Int(SG_SHM_CAPACITY) - 128
        appWrite(buf: buf,
                 left:  [Float](repeating: 0, count: prefill),
                 right: [Float](repeating: 0, count: prefill))

        let L = (0..<256).map { Float($0) * 0.003 }
        let R = (0..<256).map { Float($0) * 0.003 }
        appWrite(buf: buf, left: L, right: R)

        let out = doIO(shm: buf, frames: 256)
        for i in 0..<256 {
            let expected = (L[i] + R[i]) * 0.5
            XCTAssertEqual(out[i], expected, accuracy: 1e-4,
                "Wrap-around: out[i=\(i)] expected \(expected) got \(out[i])")
        }
    }

    // MARK: - 5. L/R asymmetry survives as mono mix

    func test_asymmetricLR_survivesAsMonoMix() {
        let buf = makeBuffer(); defer { buf.deallocate() }

        // L=1.0, R=0.0 → mono mix = 0.5
        appWrite(buf: buf,
                 left:  [Float](repeating: 1.0, count: 512),
                 right: [Float](repeating: 0.0, count: 512))

        let out = doIO(shm: buf, frames: 512)
        XCTAssertTrue(out.allSatisfy { abs($0 - 0.5) < 1e-5 },
            "L=1.0, R=0.0 → expected mono mix 0.5; got out[0]=\(out.first ?? -1)")
    }
}
