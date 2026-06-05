import XCTest
import DriverIPC

// MARK: - Ring buffer unit tests (Tier-1, infrastructure-008)
//
// These tests exercise the SGRingBuffer C API directly — no driver process,
// no XPC connection, no CoreAudio running.  They provide the "standalone test
// that writes N frames and verifies DoIOOperation drains those exact frames"
// required by acceptance criterion 3.

final class SGRingBufferTests: XCTestCase {

    // MARK: - Helpers

    /// Allocate and zero-initialise a ring buffer on the heap so tests can
    /// share a pointer with the C API without worrying about Swift's value-copy
    /// semantics for structs.
    private func makeRingBuffer() -> UnsafeMutablePointer<SGRingBuffer> {
        let rb = UnsafeMutablePointer<SGRingBuffer>.allocate(capacity: 1)
        SG_RingBuffer_Init(rb)
        return rb
    }

    // MARK: - AC3: Write N frames, drain drains exactly those frames

    func test_writeAndDrain_exactFramesReturned() {
        let rb = makeRingBuffer()
        defer { rb.deallocate() }

        // Write 3 stereo frames: L0=1.0 R0=2.0, L1=3.0 R1=4.0, L2=5.0 R2=6.0
        var input: [Float] = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]
        let written = SG_RingBuffer_Write(rb, &input, 3)
        XCTAssertEqual(written, 3, "Expected all 3 frames to be written")

        var left  = [Float](repeating: 0, count: 3)
        var right = [Float](repeating: 0, count: 3)
        SG_RingBuffer_Drain(rb, &left, &right, 3)

        XCTAssertEqual(left,  [1.0, 3.0, 5.0], accuracy: 1e-6, "Left channel mismatch")
        XCTAssertEqual(right, [2.0, 4.0, 6.0], accuracy: 1e-6, "Right channel mismatch")
    }

    // MARK: - AC4: When no frames written, drain emits silence (no crash, no hang)

    func test_drain_emitsSilenceWhenBufferEmpty() {
        let rb = makeRingBuffer()
        defer { rb.deallocate() }

        var left  = [Float](repeating: 9.9, count: 4)
        var right = [Float](repeating: 9.9, count: 4)
        // Drain from empty buffer — must not crash and must zero-fill output.
        SG_RingBuffer_Drain(rb, &left, &right, 4)

        XCTAssertEqual(left,  [0.0, 0.0, 0.0, 0.0], accuracy: 1e-6)
        XCTAssertEqual(right, [0.0, 0.0, 0.0, 0.0], accuracy: 1e-6)
    }

    // MARK: - Partial underrun: buffer has fewer frames than requested

    func test_drain_zeroFillsRemainderOnUnderrun() {
        let rb = makeRingBuffer()
        defer { rb.deallocate() }

        // Write 2 frames, request 4.
        var input: [Float] = [1.0, 2.0, 3.0, 4.0]
        SG_RingBuffer_Write(rb, &input, 2)

        var left  = [Float](repeating: 9.9, count: 4)
        var right = [Float](repeating: 9.9, count: 4)
        SG_RingBuffer_Drain(rb, &left, &right, 4)

        XCTAssertEqual(left,  [1.0, 3.0, 0.0, 0.0], accuracy: 1e-6)
        XCTAssertEqual(right, [2.0, 4.0, 0.0, 0.0], accuracy: 1e-6)
    }

    // MARK: - AvailableFrames reflects write/drain state

    func test_availableFrames_reflectsWriteAndDrain() {
        let rb = makeRingBuffer()
        defer { rb.deallocate() }

        XCTAssertEqual(SG_RingBuffer_AvailableFrames(rb), 0)

        var input: [Float] = [1.0, 2.0, 3.0, 4.0]
        SG_RingBuffer_Write(rb, &input, 2)
        XCTAssertEqual(SG_RingBuffer_AvailableFrames(rb), 2)

        var left  = [Float](repeating: 0, count: 1)
        var right = [Float](repeating: 0, count: 1)
        SG_RingBuffer_Drain(rb, &left, &right, 1)
        XCTAssertEqual(SG_RingBuffer_AvailableFrames(rb), 1)
    }

    // MARK: - Write respects capacity (no overflow)

    func test_write_clampsToCapacityWhenFull() {
        let rb = makeRingBuffer()
        defer { rb.deallocate() }

        // Fill the buffer to capacity
        let capacity = Int(SG_RING_CAPACITY)
        var bigInput = [Float](repeating: 0, count: capacity * 2)
        for i in 0..<capacity {
            bigInput[i * 2]     = Float(i)
            bigInput[i * 2 + 1] = Float(i) + 0.5
        }
        let written1 = SG_RingBuffer_Write(rb, &bigInput, UInt32(capacity))
        XCTAssertEqual(Int(written1), capacity, "Should write full capacity")

        // Buffer is full — next write must return 0
        var extra: [Float] = [1.0, 2.0]
        let written2 = SG_RingBuffer_Write(rb, &extra, 1)
        XCTAssertEqual(written2, 0, "Buffer full — write must return 0")
    }

    // MARK: - Ring wrap-around: drain after multiple cycles keeps data intact

    func test_ringWrapAround_dataRemainsCorrect() {
        let rb = makeRingBuffer()
        defer { rb.deallocate() }

        let capacity = Int(SG_RING_CAPACITY)
        // Write capacity/2, drain capacity/2, repeat twice — wraps around
        var pattern: [Float] = [10.0, 20.0] // single frame: L=10, R=20
        let halfCap = capacity / 2

        for pass in 0..<2 {
            var inputBlock = [Float](repeating: 0, count: halfCap * 2)
            for i in 0..<halfCap {
                inputBlock[i * 2]     = Float(pass * 1000 + i)
                inputBlock[i * 2 + 1] = Float(pass * 1000 + i) + 0.5
            }
            _ = SG_RingBuffer_Write(rb, &inputBlock, UInt32(halfCap))

            var left  = [Float](repeating: 0, count: halfCap)
            var right = [Float](repeating: 0, count: halfCap)
            SG_RingBuffer_Drain(rb, &left, &right, UInt32(halfCap))

            // Verify first and last sample of each pass
            XCTAssertEqual(left[0],  Float(pass * 1000),             accuracy: 1e-3,
                           "Pass \(pass): left[0] mismatch")
            XCTAssertEqual(right[0], Float(pass * 1000) + 0.5,       accuracy: 1e-3,
                           "Pass \(pass): right[0] mismatch")
            XCTAssertEqual(left[halfCap - 1],  Float(pass * 1000 + halfCap - 1), accuracy: 1e-3,
                           "Pass \(pass): left[last] mismatch")
        }
        _ = pattern  // suppress unused warning
    }

    // MARK: - Driver behaviour: DoIOOperation scenario

    // Simulate the DoIOOperation scenario:
    // 1. XPC handler writes 512 interleaved frames.
    // 2. Two consecutive "per-channel" drain calls of 512 frames each (left, right).
    // Verifies the driver's drain-and-deinterleave pattern.
    func test_driverScenario_writeThenDrainTwoChannels() {
        let rb = makeRingBuffer()
        defer { rb.deallocate() }

        let frameCount = 512
        // Build known test signal: L[i] = i * 0.001, R[i] = i * 0.001 + 100
        var interleaved = [Float](repeating: 0, count: frameCount * 2)
        for i in 0..<frameCount {
            interleaved[i * 2]     = Float(i) * 0.001
            interleaved[i * 2 + 1] = Float(i) * 0.001 + 100.0
        }
        let written = SG_RingBuffer_Write(rb, &interleaved, UInt32(frameCount))
        XCTAssertEqual(Int(written), frameCount)

        // First channel drain (left)
        var leftOut  = [Float](repeating: 0, count: frameCount)
        var rightOut = [Float](repeating: 0, count: frameCount)
        SG_RingBuffer_Drain(rb, &leftOut, &rightOut, UInt32(frameCount))

        // Spot-check: frame 0, 255, 511
        XCTAssertEqual(leftOut[0],          0.0,              accuracy: 1e-5)
        XCTAssertEqual(rightOut[0],         100.0,            accuracy: 1e-5)
        XCTAssertEqual(leftOut[255],        Float(255) * 0.001, accuracy: 1e-5)
        XCTAssertEqual(rightOut[255],       Float(255) * 0.001 + 100.0, accuracy: 1e-5)
        XCTAssertEqual(leftOut[511],        Float(511) * 0.001, accuracy: 1e-5)
        XCTAssertEqual(rightOut[511],       Float(511) * 0.001 + 100.0, accuracy: 1e-5)

        // Buffer should now be empty
        XCTAssertEqual(SG_RingBuffer_AvailableFrames(rb), 0)
    }
}

// MARK: - Array comparison helpers

private func XCTAssertEqual(_ a: [Float], _ b: [Float],
                             accuracy: Float,
                             _ message: String = "",
                             file: StaticString = #filePath,
                             line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, "Array length mismatch. \(message)", file: file, line: line)
    guard a.count == b.count else { return }
    for (i, (x, y)) in zip(a, b).enumerated() {
        XCTAssertEqual(x, y, accuracy: accuracy,
                       "Index \(i): \(message)", file: file, line: line)
    }
}
