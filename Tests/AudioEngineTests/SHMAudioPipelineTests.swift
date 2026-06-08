import XCTest
import AVFAudio
import DriverIPC
@testable import AudioEngine

// MARK: - SHM Audio Pipeline Tests
//
// These tests verify the complete audio data path from adapter delivery
// through the Mixer to either:
//   (a) the FakeDriverIPCConnection (fast, in-process, no SHM)
//   (b) the real SHMDriverIPCConnection (reads actual POSIX SHM bytes)
//
// The existing DriverOutputAdapterTests only check STATE (started/stopped).
// These tests check DATA FLOW: that non-zero audio actually reaches writeSamples.

// MARK: - Helpers

private let kMixTargetFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 48_000,
    channels: 2,
    interleaved: false
)!

/// Build a 440 Hz sine-wave buffer in the mix-target format (48 kHz, float32, NI stereo).
private func makeSineBuffer(amplitude: Float = 0.5, frameCount: Int = 960) -> AVAudioPCMBuffer {
    let buf = AVAudioPCMBuffer(pcmFormat: kMixTargetFormat,
                               frameCapacity: AVAudioFrameCount(frameCount))!
    buf.frameLength = AVAudioFrameCount(frameCount)
    let ch0 = buf.floatChannelData![0]
    let ch1 = buf.floatChannelData![1]
    for i in 0..<frameCount {
        let t = Float(i) / 48_000.0
        let s = amplitude * sinf(2 * .pi * 440.0 * t)
        ch0[i] = s
        ch1[i] = s
    }
    return buf
}

/// Decode a writeSamples `Data` blob back to [Float] for inspection.
private func floats(from data: Data) -> [Float] {
    data.withUnsafeBytes { raw in
        Array(raw.bindMemory(to: Float.self))
    }
}

// MARK: - Tests

final class SHMAudioPipelineTests: XCTestCase {

    // MARK: - Shared pipeline helpers

    private func makePipeline() -> (
        pipeline: AudioPipeline,
        sysAudio: FakeUpstreamCaptureAdapter
    ) {
        let s = FakeUpstreamCaptureAdapter()
        return (AudioPipeline(systemAudioAdapter: s, micAdapter: FakeUpstreamCaptureAdapter()), s)
    }

    // MARK: - 1. No buffer → no writeSamples calls (IOProc-driven model)

    func test_noBuffer_noWriteSamplesCalls() {
        // In the direct-write model, writeSamples is only called when the IOProc
        // delivers a buffer. Without a buffer, no write happens and the SHM stays at
        // writePos=0 — the driver delivers silence by reading zeros.
        let (pipeline, _) = makePipeline()
        let fakeIPC = FakeDriverIPCConnection()
        let adapter = DriverOutputAdapter(pipeline: pipeline, ipc: fakeIPC)

        fakeIPC.simulateConsumerActive(true)
        adapter.syncBarrier()
        Thread.sleep(forTimeInterval: 0.025)
        adapter.syncBarrier()

        XCTAssertTrue(fakeIPC.writeSamplesCalls.isEmpty,
            "No buffer was emitted — writeSamples should not be called " +
            "(driver reads zeros from SHM when writePos=0).")
    }

    // MARK: - 2. Second system-audio buffer with different amplitude also reaches writeSamples

    func test_sysAudioBuffer_secondEmit_alsoCaptured() {
        let (pipeline, sysAudio) = makePipeline()
        let fakeIPC = FakeDriverIPCConnection()
        let adapter = DriverOutputAdapter(pipeline: pipeline, ipc: fakeIPC)

        fakeIPC.simulateConsumerActive(true)
        adapter.syncBarrier()

        sysAudio.emitBuffer(makeSineBuffer(amplitude: 0.5))
        Thread.sleep(forTimeInterval: 0.030)
        adapter.syncBarrier()
        let count1 = fakeIPC.writeSamplesCalls.count

        sysAudio.emitBuffer(makeSineBuffer(amplitude: 0.2))
        Thread.sleep(forTimeInterval: 0.030)
        adapter.syncBarrier()

        XCTAssertGreaterThan(fakeIPC.writeSamplesCalls.count, count1,
            "Render timer stopped after the first tick — writeSamples not called on subsequent ticks.")
    }

    // MARK: - 3. System-audio buffer flows to writeSamples as non-zero data

    func test_sysAudioBuffer_reachesWriteSamples_asNonZero() {
        let (pipeline, sysAudio) = makePipeline()
        let fakeIPC = FakeDriverIPCConnection()
        let adapter = DriverOutputAdapter(pipeline: pipeline, ipc: fakeIPC)

        fakeIPC.simulateConsumerActive(true)
        adapter.syncBarrier()

        sysAudio.emitBuffer(makeSineBuffer(amplitude: 0.3))

        Thread.sleep(forTimeInterval: 0.030)
        adapter.syncBarrier()

        let hasNonZero = fakeIPC.writeSamplesCalls.contains { call in
            floats(from: call.data).contains { abs($0) > 1e-4 }
        }
        XCTAssertTrue(hasNonZero,
            "System-audio buffer did not produce non-zero output. " +
            "StagingBuffer.store() may be rejecting the buffer or Mixer.mix() returns zeros.")
    }

    // MARK: - 4. System audio amplitude is preserved (not clipped or attenuated)

    func test_sysAudio_amplitudePreserved() {
        let (pipeline, sysAudio) = makePipeline()
        let fakeIPC = FakeDriverIPCConnection()
        let adapter = DriverOutputAdapter(pipeline: pipeline, ipc: fakeIPC)

        fakeIPC.simulateConsumerActive(true)
        adapter.syncBarrier()

        let expected: Float = 0.4
        sysAudio.emitBuffer(makeSineBuffer(amplitude: expected))

        Thread.sleep(forTimeInterval: 0.030)
        adapter.syncBarrier()

        let nonZeroCalls = fakeIPC.writeSamplesCalls.filter { call in
            floats(from: call.data).contains { abs($0) > 1e-4 }
        }
        XCTAssertFalse(nonZeroCalls.isEmpty, "No non-zero output after system audio injection.")

        let peak = nonZeroCalls.last.map { floats(from: $0.data).map(abs).max() ?? 0 } ?? 0
        XCTAssertGreaterThan(peak, expected * 0.8,
            "Output peak \(peak) too low vs injected \(expected). Amplitude may be attenuated.")
    }

    // MARK: - 5. No buffer → no writes (silence by omission)

    func test_noBuffer_noWriteHappens() {
        // Without an upstream buffer, no writeSamples call is made.
        // The SHM stays at writePos=0 and the driver delivers silence natively.
        let (pipeline, _) = makePipeline()
        let fakeIPC = FakeDriverIPCConnection()
        let adapter = DriverOutputAdapter(pipeline: pipeline, ipc: fakeIPC)

        fakeIPC.simulateConsumerActive(true)
        adapter.syncBarrier()
        Thread.sleep(forTimeInterval: 0.030)
        adapter.syncBarrier()

        XCTAssertTrue(fakeIPC.writeSamplesCalls.isEmpty,
            "No buffer emitted — writeSamples must not be called.")
    }

    // MARK: - 6. Consumer detach stops audio flow

    func test_consumerDetach_stopsAudioFlow() {
        let (pipeline, sysAudio) = makePipeline()
        let fakeIPC = FakeDriverIPCConnection()
        let adapter = DriverOutputAdapter(pipeline: pipeline, ipc: fakeIPC)

        fakeIPC.simulateConsumerActive(true)
        adapter.syncBarrier()
        sysAudio.emitBuffer(makeSineBuffer(amplitude: 0.8))

        Thread.sleep(forTimeInterval: 0.030)
        adapter.syncBarrier()

        // Detach consumer → render timer should stop
        fakeIPC.simulateConsumerActive(false)
        adapter.syncBarrier()

        let countAtDetach = fakeIPC.writeSamplesCalls.count
        Thread.sleep(forTimeInterval: 0.030)
        adapter.syncBarrier()

        XCTAssertEqual(fakeIPC.writeSamplesCalls.count, countAtDetach,
            "Render timer kept firing after consumer detached — audio still flowing when it should have stopped.")
    }

    // MARK: - 7. SHM layout: writeSamples stores samples at offset 16, writePos at offset 0

    func test_shmLayout_writePos_and_samples_atCorrectOffsets() throws {
        // Open the real POSIX SHM that SHMDriverIPCConnection creates.
        // This test verifies the byte layout matches what StimmgabelDriver.c expects:
        //   offset  0: uint64_t writePos
        //   offset  8: uint64_t readPos  (not written by app)
        //   offset 16: float32 samples[4096*2]

        let conn = SHMDriverIPCConnection()
        conn.connect()

        // Allow time for openSHM() async work to complete.
        Thread.sleep(forTimeInterval: 0.05)

        // Write known test data: 1 render frame of samples[0]=0.123, samples[1]=0.456
        // by delivering a buffer where the first stereo frame has those exact values.
        let buf = AVAudioPCMBuffer(pcmFormat: kMixTargetFormat, frameCapacity: 512)!
        buf.frameLength = 512
        let ch0 = buf.floatChannelData![0]
        let ch1 = buf.floatChannelData![1]
        // Set only the first sample to a distinctive value.
        ch0[0] = 0.123
        ch1[0] = 0.456
        for i in 1..<512 { ch0[i] = 0; ch1[i] = 0 }

        // Build the interleaved data that writeSamples expects (512 stereo frames).
        var interleaved = [Float](repeating: 0, count: 1024)
        interleaved[0] = 0.123   // L sample of frame 0
        interleaved[1] = 0.456   // R sample of frame 0

        let data = interleaved.withUnsafeBufferPointer { ptr in Data(buffer: ptr) }
        conn.writeSamples(data, frameCount: 512)

        // Allow the async write to complete.
        Thread.sleep(forTimeInterval: 0.02)

        // Now open the SHM read-only and inspect raw bytes.
        // Use sg_shm_open (DriverIPC wrapper) because shm_open is variadic/unavailable in Swift.
        let shmName = SG_SHM_NAME   // "/stimmgabel-audio-v1"
        let fd = sg_shm_open(shmName, O_RDONLY, 0)
        guard fd >= 0 else {
            throw XCTSkip("SHM segment \(shmName) not found — run after Stimmgabel has launched once")
        }
        defer { close(fd) }

        let kSize = 8 + 8 + 4096 * 2 * 4   // 32784 bytes
        guard let ptr = mmap(nil, kSize, PROT_READ, MAP_SHARED, fd, 0),
              ptr != MAP_FAILED else {
            XCTFail("mmap failed: \(errno)")
            return
        }
        defer { munmap(ptr, kSize) }

        // Read writePos (offset 0, 8 bytes).
        let writePosPtr = ptr.assumingMemoryBound(to: UInt64.self)
        let writePos = writePosPtr.pointee
        XCTAssertGreaterThan(writePos, 0,
            "writePos should be > 0 after writeSamples; got \(writePos). " +
            "writeToSHM may not be advancing writePos.")

        // The written frames are at positions (writePos - 512) ... (writePos - 1) mod 4096.
        // Read back the first frame we wrote (position (writePos - 512) % 4096).
        let samplesBase = ptr.advanced(by: 16).assumingMemoryBound(to: Float.self)
        let firstSlot = Int((writePos - 512) % 4096)
        let readL = samplesBase[firstSlot * 2]
        let readR = samplesBase[firstSlot * 2 + 1]

        XCTAssertEqual(readL, 0.123, accuracy: 1e-5,
            "Left sample at slot \(firstSlot) should be 0.123; got \(readL). " +
            "SHM layout mismatch or wrong slot calculation.")
        XCTAssertEqual(readR, 0.456, accuracy: 1e-5,
            "Right sample at slot \(firstSlot) should be 0.456; got \(readR). " +
            "SHM layout mismatch or wrong slot calculation.")
    }
}

// MARK: - Mic conversion tests
//
// These tests verify that the MicAdapter's AudioConverter path (e.g. AirPods 24 kHz mono →
// 48 kHz stereo) produces a correctly-formatted buffer that the StagingBuffer accepts.
// They bypass the real HAL by calling the conversion logic directly.

final class MicFormatConversionTests: XCTestCase {

    /// The mix-target format the whole pipeline uses.
    private let mixTarget = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    )!

    private func makePipeline() -> (
        pipeline: AudioPipeline,
        sysAudio: FakeUpstreamCaptureAdapter
    ) {
        let s = FakeUpstreamCaptureAdapter()
        return (AudioPipeline(systemAudioAdapter: s, micAdapter: FakeUpstreamCaptureAdapter()), s)
    }

    // MARK: - Helper: fake input ABL at 24 kHz mono (AirPods HFP)

    /// Build a 24 kHz mono float32 AudioBufferList with a known sine-wave signal.
    /// Returns the ABL and a Data buffer whose lifetime must outlive the ABL pointer.
    private func makeAirPodsABL(frames: Int, amplitude: Float = 0.5)
        -> (abl: AudioBufferList, storage: [Float])
    {
        var samples = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            samples[i] = amplitude * sinf(2 * .pi * 440 * Float(i) / 24_000)
        }
        var abl = AudioBufferList()
        abl.mNumberBuffers = 1
        abl.mBuffers.mNumberChannels = 1
        abl.mBuffers.mDataByteSize   = UInt32(frames * MemoryLayout<Float>.size)
        abl.mBuffers.mData           = nil  // set via pointer after return
        return (abl, samples)
    }

    // MARK: - 8. AudioConverter 24 kHz mono → 48 kHz stereo produces non-zero output

    func test_airpodsConversion_24kHzMono_to_48kHzStereo_nonZero() throws {
        // Build a 24 kHz mono ASBD (AirPods HFP format).
        var srcASBD = AudioStreamBasicDescription()
        srcASBD.mSampleRate       = 24_000
        srcASBD.mFormatID         = kAudioFormatLinearPCM
        srcASBD.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        srcASBD.mBitsPerChannel   = 32
        srcASBD.mChannelsPerFrame = 1
        srcASBD.mFramesPerPacket  = 1
        srcASBD.mBytesPerFrame    = 4
        srcASBD.mBytesPerPacket   = 4

        var dstASBD = AudioStreamBasicDescription()
        dstASBD.mSampleRate       = 48_000
        dstASBD.mFormatID         = kAudioFormatLinearPCM
        dstASBD.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved
        dstASBD.mBitsPerChannel   = 32
        dstASBD.mChannelsPerFrame = 2
        dstASBD.mFramesPerPacket  = 1
        dstASBD.mBytesPerFrame    = 4
        dstASBD.mBytesPerPacket   = 4

        var cvt: AudioConverterRef?
        let createStatus = AudioConverterNew(&srcASBD, &dstASBD, &cvt)
        XCTAssertEqual(createStatus, noErr, "AudioConverterNew should succeed for 24→48 kHz conversion")
        guard let converter = cvt else { return }
        defer { AudioConverterDispose(converter) }

        // 480 input frames (10 ms at 24 kHz) → 960 output frames (10 ms at 48 kHz).
        let inputFrames  = 480
        let outputFrames = 960
        var inputSamples = [Float](repeating: 0, count: inputFrames)
        for i in 0..<inputFrames {
            inputSamples[i] = 0.5 * sinf(2 * .pi * 440 * Float(i) / 24_000)
        }

        let outputBuf = AVAudioPCMBuffer(pcmFormat: mixTarget,
                                         frameCapacity: AVAudioFrameCount(outputFrames))!
        outputBuf.frameLength = AVAudioFrameCount(outputFrames)

        // Build input context.
        struct Ctx { var ptr: UnsafePointer<Float>; var total: UInt32; var consumed: UInt32 }
        var ctx = inputSamples.withUnsafeBufferPointer { bp -> Ctx in
            Ctx(ptr: bp.baseAddress!, total: UInt32(inputFrames), consumed: 0)
        }
        var ioPackets = UInt32(outputFrames)

        inputSamples.withUnsafeBufferPointer { inputBP in
            ctx.ptr = inputBP.baseAddress!
            withUnsafeMutablePointer(to: &outputBuf.mutableAudioBufferList.pointee) { outABL in
                withUnsafeMutablePointer(to: &ctx) { ctxPtr in
                    AudioConverterFillComplexBuffer(
                        converter,
                        { _, ioDP, ioData, _, ud in
                            guard let ud else { return kAudioConverterErr_UnspecifiedError }
                            let c = ud.assumingMemoryBound(to: Ctx.self)
                            let rem = c.pointee.total - c.pointee.consumed
                            guard rem > 0 else { ioDP.pointee = 0; return noErr }
                            let provide = min(ioDP.pointee, rem)
                            let offset  = Int(c.pointee.consumed)
                            ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(
                                mutating: c.pointee.ptr.advanced(by: offset))
                            ioData.pointee.mBuffers.mDataByteSize = provide * 4
                            ioDP.pointee = provide
                            c.pointee.consumed += provide
                            return noErr
                        },
                        UnsafeMutableRawPointer(ctxPtr),
                        &ioPackets,
                        outABL,
                        nil
                    )
                }
            }
        }

        // The converter must produce the expected number of output frames.
        XCTAssertGreaterThanOrEqual(ioPackets, UInt32(outputFrames / 2),
            "Converter should produce roughly \(outputFrames) frames; got \(ioPackets). " +
            "If 0: the input callback is not wired correctly.")

        // The output must be non-zero (we fed a 440 Hz sine).
        guard let ch0 = outputBuf.floatChannelData?[0] else {
            XCTFail("floatChannelData is nil — buffer not in expected format")
            return
        }
        let peak = (0..<Int(ioPackets)).reduce(0.0 as Float) { max($0, abs(ch0[$1])) }
        XCTAssertGreaterThan(peak, 0.01,
            "Converted output should be non-zero for a 440 Hz 0.5-amplitude input; peak=\(peak). " +
            "Possible cause: input callback returns 0 packets on first call.")
    }

    // MARK: - 9. StagingBuffer accepts MicAdapter output format

    func test_stagingBuffer_acceptsMixTargetFormat() {
        // Verify StagingBuffer.store() doesn't silently drop a buffer in the mix-target format.
        let buf = AVAudioPCMBuffer(pcmFormat: mixTarget, frameCapacity: 512)!
        buf.frameLength = 512
        if let ch0 = buf.floatChannelData?[0], let ch1 = buf.floatChannelData?[1] {
            for i in 0..<512 { ch0[i] = 0.3; ch1[i] = 0.3 }
        }

        let staging = StagingBuffer()
        staging.store(buf)

        let drained = staging.drain(frameCount: 512)
        XCTAssertEqual(drained.count, 512 * 2,
            "Expected 1024 interleaved floats (512 stereo frames); got \(drained.count).")
        let peak = drained.map(abs).max() ?? 0
        XCTAssertGreaterThan(peak, 0.1,
            "Drained samples should be ~0.3; got peak=\(peak). " +
            "StagingBuffer.store() may be producing wrong interleaving.")
    }

    // MARK: - 10. Full pipeline: 24 kHz mono input → non-zero SHM output (AirPods scenario)

    func test_fullPipeline_withAirPodsLevelAudio_producesNonZeroSHMOutput() {
        // End-to-end test: inject audio at typical AirPods speaking volume (peak ~0.15)
        // and verify the output reaches the SHM write layer at a detectable level.
        // This catches issues where the signal is too attenuated to be useful.

        let (pipeline, sysAudio) = makePipeline()
        let fakeIPC = FakeDriverIPCConnection()
        let adapter = DriverOutputAdapter(pipeline: pipeline, ipc: fakeIPC)

        fakeIPC.simulateConsumerActive(true)
        adapter.syncBarrier()

        // Typical speaking-level audio: peak ~0.15 (about -16 dBFS).
        sysAudio.emitBuffer(makeSineBuffer(amplitude: 0.15))

        Thread.sleep(forTimeInterval: 0.030)
        adapter.syncBarrier()

        let peaks = fakeIPC.writeSamplesCalls.map { call -> Float in
            floats(from: call.data).reduce(0) { max($0, abs($1)) }
        }
        let maxPeak = peaks.max() ?? 0
        XCTAssertGreaterThan(maxPeak, 0.05,
            "At speaking volume (amplitude 0.15), output peak should be > 0.05; got \(maxPeak). " +
            "This means the pipeline is attenuating or dropping audio before it reaches the driver.")
    }
}

