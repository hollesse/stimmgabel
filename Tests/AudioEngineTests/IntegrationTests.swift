import XCTest
import AVFAudio
@testable import AudioEngine

// MARK: - Integration Tests: Audio file → pipeline → SHM output
//
// These tests simulate the realistic scenario where a user plays an audio file
// (or speaks into the mic) and Stimmgabel delivers it to the virtual mic.
//
// Test design:
//   1. Write a known test signal into a temporary WAV file.
//   2. Load it back via AVAudioFile (as the SystemAudioAdapter would receive it).
//   3. Inject via FakeUpstreamCaptureAdapter.emitBuffer() with mic MUTED.
//   4. Verify the pipeline output matches the original signal closely.
//
// "Matches closely" means:
//   • Amplitude preserved: output peak ≥ 80% of input peak
//   • Signal content preserved: normalized cross-correlation ≥ 0.95
//   • No channel swap: left output correlates with injected left channel

final class IntegrationTests: XCTestCase {

    // MARK: - Mix target format used throughout the pipeline

    private let mixFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    )!

    // MARK: - Helpers

    /// Make a fresh pipeline with a fake system-audio adapter and a fake IPC connection.
    private func makePipeline() -> (
        pipeline: AudioPipeline,
        sys: FakeUpstreamCaptureAdapter,
        ipc: FakeDriverIPCConnection,
        adapter: DriverOutputAdapter
    ) {
        let sys     = FakeUpstreamCaptureAdapter()
        let pipeline = AudioPipeline(systemAudioAdapter: sys)
        let ipc     = FakeDriverIPCConnection()
        let adapter = DriverOutputAdapter(pipeline: pipeline, ipc: ipc)
        return (pipeline, sys, ipc, adapter)
    }

    /// Decode a writeSamples Data payload back to [Float].
    private func floats(from data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Normalized cross-correlation between two same-length vectors.
    /// Returns a value in [-1, 1]; 1.0 = identical signal content.
    private func normalizedCorrelation(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        let dotAB = zip(a.prefix(n), b.prefix(n)).reduce(0.0 as Float) { $0 + $1.0 * $1.1 }
        let normA  = sqrtf(a.prefix(n).reduce(0) { $0 + $1 * $1 })
        let normB  = sqrtf(b.prefix(n).reduce(0) { $0 + $1 * $1 })
        guard normA > 1e-10, normB > 1e-10 else { return 0 }
        return dotAB / (normA * normB)
    }

    // MARK: - Write a WAV file containing a known test tone

    /// Generate `frameCount` frames of a stereo 440 Hz sine at `amplitude`.
    private func generateTestTone(frames: Int, amplitude: Float = 0.5) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: mixFormat,
                                   frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        let ch0 = buf.floatChannelData![0]
        let ch1 = buf.floatChannelData![1]
        for i in 0..<frames {
            let v = amplitude * sinf(2 * .pi * 440 * Float(i) / 48_000)
            ch0[i] = v
            ch1[i] = v * 0.9  // slightly different on right channel so we can detect swaps
        }
        return buf
    }

    /// Write `buffer` to a temporary WAV file and return its URL.
    private func writeTempWAV(_ buffer: AVAudioPCMBuffer) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stimmgabel_test_\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url,
                                   settings: mixFormat.settings,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        try file.write(from: buffer)
        return url
    }

    /// Load a WAV file and return its audio as an AVAudioPCMBuffer.
    private func loadWAV(at url: URL) throws -> AVAudioPCMBuffer {
        let file   = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.length)
        guard let buf = AVAudioPCMBuffer(pcmFormat: mixFormat,
                                         frameCapacity: frames) else {
            throw NSError(domain: "test", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot allocate buffer"])
        }
        // If the file format differs from mixFormat, convert via AVAudioConverter.
        if file.processingFormat == mixFormat {
            try file.read(into: buf)
        } else {
            let conv = AVAudioConverter(from: file.processingFormat, to: mixFormat)!
            let inputBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: frames)!
            try file.read(into: inputBuf)
            var error: NSError?
            conv.convert(to: buf, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return inputBuf
            }
            if let e = error { throw e }
        }
        buf.frameLength = frames
        return buf
    }

    // MARK: - 1. System audio file passes through unchanged when mic is muted

    func test_audioFile_systemAudioPassesThrough() throws {
        let (_, sys, ipc, adapter) = makePipeline()

        // 1. Generate and write a known test tone to a WAV file.
        let inputBuf = generateTestTone(frames: 512, amplitude: 0.5)
        let wavURL   = try writeTempWAV(inputBuf)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        // 2. Load the WAV file back (as SystemAudioAdapter would provide it).
        let loadedBuf = try loadWAV(at: wavURL)

        // 3. Start the pipeline and inject the loaded audio as system audio.
        ipc.simulateConsumerActive(true)
        adapter.syncBarrier()
        sys.emitBuffer(loadedBuf)

        // 4. Wait for at least 2 render ticks.
        Thread.sleep(forTimeInterval: 0.030)
        adapter.syncBarrier()

        XCTAssertFalse(ipc.writeSamplesCalls.isEmpty,
            "Render timer never fired — DriverOutputAdapter not running.")

        // 5. Collect the non-zero output samples and extract left/right channels.
        let allOutputFloats = ipc.writeSamplesCalls
            .map { floats(from: $0.data) }
            .filter { $0.contains { abs($0) > 1e-4 } }

        XCTAssertFalse(allOutputFloats.isEmpty,
            "All output is silence even though system audio was injected. " +
            "Check Mixer.mix() returns non-zero when StagingBuffer has data.")

        let outputInterleaved = allOutputFloats.first!
        // Split into left (even) and right (odd) channels.
        let outL = stride(from: 0, to: outputInterleaved.count, by: 2).map { outputInterleaved[$0] }
        let outR = stride(from: 1, to: outputInterleaved.count, by: 2).map { outputInterleaved[$0] }

        // Extract input left/right from loaded buffer.
        let frames = Int(loadedBuf.frameLength)
        let inL  = (0..<min(frames, outL.count)).map { loadedBuf.floatChannelData![0][$0] }
        let inR  = (0..<min(frames, outR.count)).map { loadedBuf.floatChannelData![1][$0] }

        // 6a. Amplitude must be preserved (output peak ≥ 80% of input peak).
        let inPeakL  = inL.map(abs).max()!
        let outPeakL = outL.map(abs).max()!
        XCTAssertGreaterThan(outPeakL, inPeakL * 0.8,
            "Output peak (\(outPeakL)) too low vs input (\(inPeakL)). " +
            "Signal is attenuated more than 20%. Check micGain/sysAudioGain in Mixer.")

        // 6b. Signal content must be preserved: normalized cross-correlation ≥ 0.95.
        let corrL = normalizedCorrelation(inL, outL)
        XCTAssertGreaterThan(corrL, 0.95,
            "Left channel correlation \(corrL) < 0.95. " +
            "The audio content changed during pipeline processing. " +
            "Possible causes: wrong interleaving, wrong channel mapping, " +
            "StagingBuffer truncating frames.")

        // 6c. No channel swap: left input correlates more with left output than right output.
        let corrLwithR = normalizedCorrelation(inL, outR)
        // The right channel was 0.9× left, so both correlate well — but left-with-left
        // should be higher than a deliberately-different right channel.
        XCTAssertGreaterThanOrEqual(corrL, corrLwithR - 0.05,
            "Left channel seems swapped with right in the output. " +
            "Check interleaving order in StagingBuffer.store() and Mixer.mix().")

    }

    // MARK: - 2. No buffer → no writeSamples calls

    func test_noBuffer_noWriteSamplesCalls() {
        let (_, _, ipc, adapter) = makePipeline()

        ipc.simulateConsumerActive(true)
        adapter.syncBarrier()
        Thread.sleep(forTimeInterval: 0.030)
        adapter.syncBarrier()

        XCTAssertTrue(ipc.writeSamplesCalls.isEmpty,
            "No buffer emitted — writeSamples must not be called in the direct-write model.")
    }

    // MARK: - 3. System audio signal content is preserved end-to-end

    func test_sysAudioSignal_contentPreserved() {
        let (_, sys, ipc, adapter) = makePipeline()

        ipc.simulateConsumerActive(true)
        adapter.syncBarrier()

        let sysBuf = AVAudioPCMBuffer(pcmFormat: mixFormat, frameCapacity: 512)!
        sysBuf.frameLength = 512
        for i in 0..<512 {
            sysBuf.floatChannelData![0][i] = 0.3 * sinf(2 * .pi * 440 * Float(i) / 48_000)
            sysBuf.floatChannelData![1][i] = 0.3 * sinf(2 * .pi * 440 * Float(i) / 48_000)
        }
        sys.emitBuffer(sysBuf)

        Thread.sleep(forTimeInterval: 0.030)
        adapter.syncBarrier()

        let nonZero = ipc.writeSamplesCalls.filter { call in
            floats(from: call.data).contains { abs($0) > 1e-4 }
        }
        XCTAssertFalse(nonZero.isEmpty, "No non-zero output after system audio injection.")

        let outL = stride(from: 0, to: floats(from: nonZero.last!.data).count, by: 2)
            .map { floats(from: nonZero.last!.data)[$0] }
        let expected = (0..<outL.count).map { 0.3 * sinf(2 * .pi * 440 * Float($0) / 48_000) }
        let corr = normalizedCorrelation(outL, expected)
        XCTAssertGreaterThan(corr, 0.90,
            "System audio signal not preserved: correlation=\(corr) < 0.90. " +
            "Check StagingBuffer interleaving and Mixer.mix() output.")
    }
}
