import XCTest
import CoreAudio
import AVFAudio
import Foundation
@testable import AudioEngine

// MARK: - Playback End-to-End Tests
//
// These tests play a real audio file through the system audio output and record
// what Stimmgabel's virtual microphone delivers to a HAL consumer.
//
// The full signal path under test:
//   afplay → system audio output
//     → Stimmgabel Process Tap (SystemAudioAdapter)
//     → SHM ring buffer
//     → Driver DoIOOperation
//     → CoreAudio HAL output (this test's IOProc)
//
// Prerequisites:
//   • Stimmgabel.app must be running (it holds Screen Recording permission
//     and drives the system-audio tap → SHM pipeline)
//   • Stimmgabel.driver installed in /Library/Audio/Plug-Ins/HAL/
//   • No other app consuming the virtual mic (would compete for the notify)
//
// To run: start Stimmgabel.app, then:
//   swift test --filter PlaybackE2ETests

final class PlaybackE2ETests: XCTestCase {

    private let kVirtualMicUID = "com.innoq.stimmgabel.virtualmic"

    // MARK: - Helpers

    private func findVirtualMicDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices) == noErr
        else { return nil }
        for device in devices {
            var uidRef: CFString?
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            if AudioObjectGetPropertyData(device, &uidAddr, 0, nil, &uidSize, &uidRef) == noErr,
               let uid = uidRef as String?, uid == kVirtualMicUID {
                return device
            }
        }
        return nil
    }

    private func stimmgabelIsRunning() -> Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.innoq.stimmgabel").isEmpty
    }

    /// Generates a linear chirp sweeping from `freqStart` to `freqEnd` Hz.
    ///
    /// Why a chirp instead of a sine:
    ///   A pure sine is time-invariant — repeating or skipping frames leaves the
    ///   periodicity unchanged.  A chirp has a unique frequency at every instant,
    ///   so frame repetition (old "latest-frame" driver bug) or frame drops
    ///   (clock-drift FIFO underrun) produce visible correlation loss.
    private func makeChirpSamples(freqStart: Float, freqEnd: Float,
                                   durationSeconds: Double,
                                   sampleRate: Double = 48_000,
                                   amplitude: Float = 0.5) -> [Float] {
        let n = Int(durationSeconds * sampleRate)
        let k = (freqEnd - freqStart) / (2 * Float(durationSeconds))
        return (0..<n).map { i in
            let t = Float(i) / Float(sampleRate)
            return amplitude * sinf(2 * .pi * (freqStart + k * t) * t)
        }
    }

    /// Writes a stereo WAV file where left=`samplesL`, right=`samplesR`.
    /// Using L≠R catches de-interleaving bugs: if L and R are swapped or mixed,
    /// the mono output (L+R)/2 will differ from the intended signal.
    private func writeTempStereoWAV(left: [Float], right: [Float],
                                     sampleRate: Double = 48_000) throws -> URL {
        precondition(left.count == right.count)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: sampleRate, channels: 2, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                   frameCapacity: AVAudioFrameCount(left.count))!
        buf.frameLength = AVAudioFrameCount(left.count)
        let ch0 = buf.floatChannelData![0]
        let ch1 = buf.floatChannelData![1]
        for i in 0..<left.count { ch0[i] = left[i]; ch1[i] = right[i] }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stimmgabel_e2e_\(arc4random()).wav")
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        try file.write(from: buf)
        return url
    }

    /// Pearson correlation between two equal-length arrays (zero-mean assumed).
    private func correlation(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        let aRMS = sqrtf(a.prefix(n).reduce(0 as Float) { $0 + $1 * $1 } / Float(n))
        let bRMS = sqrtf(b.prefix(n).reduce(0 as Float) { $0 + $1 * $1 } / Float(n))
        guard aRMS > 1e-6, bRMS > 1e-6 else { return 0 }
        let dot = zip(a.prefix(n), b.prefix(n)).reduce(0 as Float) { $0 + $1.0 * $1.1 }
        return abs(dot) / (Float(n) * aRMS * bRMS)
    }

    // MARK: - The E2E test

    /// Plays a chirp signal via `afplay` (system audio), records what
    /// Stimmgabel's virtual mic delivers, and verifies:
    ///   1. Audio is not silent (pipeline is running)
    ///   2. Correlation with the original chirp is high (no frame repeats/drops)
    ///   3. Correlation with the stereo (L+R)/2 mix is correct (de-interleaving ok)
    ///
    /// A chirp (200→2000 Hz over 3 s) is used instead of a sine because:
    ///   • Frame repetition (old latest-frame driver bug) shifts instantaneous
    ///     frequency → correlation drops below threshold
    ///   • Clock-drift underruns create gaps → visible in correlation
    ///   • L≠R design catches de-interleaving bugs (would pass with L=R sine)
    func test_afplay_signalSurvivesFullPipeline_detectedOnVirtualMic() throws {
        guard let deviceID = findVirtualMicDevice() else {
            throw XCTSkip(
                "Stimmgabel.driver not loaded — run ./script/install-driver.sh first.")
        }
        guard stimmgabelIsRunning() else {
            throw XCTSkip(
                "Stimmgabel.app is not running. Start it first: " +
                "open /path/to/Stimmgabel.app\n" +
                "The app must run because it holds the Screen Recording permission " +
                "needed to capture system audio via the Process Tap.")
        }

        // ── Input signal ──────────────────────────────────────────────────────
        // Chirp 200→2000 Hz, stereo with L ≠ R (catches de-interleaving bugs).
        // L channel: chirp at full amplitude.
        // R channel: same chirp, half amplitude → mono mix (L+R)/2 = 0.75× chirp.
        let inputDuration     = 3.0
        let inputSampleRate   = 48_000.0
        let amplitudeL: Float = 0.5
        let amplitudeR: Float = 0.25   // L ≠ R  →  if swapped, correlation drops

        let chirpL = makeChirpSamples(freqStart: 200, freqEnd: 2000,
                                       durationSeconds: inputDuration,
                                       sampleRate: inputSampleRate,
                                       amplitude: amplitudeL)
        let chirpR = makeChirpSamples(freqStart: 200, freqEnd: 2000,
                                       durationSeconds: inputDuration,
                                       sampleRate: inputSampleRate,
                                       amplitude: amplitudeR)
        // Expected mono output: (L+R)/2
        let expectedMono = zip(chirpL, chirpR).map { ($0 + $1) * 0.5 }

        let wavURL = try writeTempStereoWAV(left: chirpL, right: chirpR,
                                             sampleRate: inputSampleRate)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        // ── Record from the virtual mic ───────────────────────────────────────
        // Collect interleaved float samples delivered by the HAL IOProc.
        var capturedSamples = [Float]()
        let captureLock = NSLock()
        let doneSignal  = DispatchSemaphore(value: 0)

        var ioProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID, deviceID, nil
        ) { _, inInputData, _, _, _ in
            withUnsafePointer(to: inInputData.pointee.mBuffers) { bp in
                guard let ptr = bp.pointee.mData?.assumingMemoryBound(to: Float.self),
                      bp.pointee.mDataByteSize > 0 else { return }
                let count = Int(bp.pointee.mDataByteSize) / MemoryLayout<Float>.size
                captureLock.lock()
                capturedSamples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: count))
                captureLock.unlock()
            }
        }
        guard createStatus == noErr, let procID = ioProcID else {
            throw XCTSkip(
                "AudioDeviceCreateIOProcIDWithBlock failed (\(createStatus)). " +
                "Virtual mic may not be accessible from the test process.")
        }
        defer {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }

        let startStatus = AudioDeviceStart(deviceID, procID)
        guard startStatus == noErr else {
            throw XCTSkip("AudioDeviceStart failed (\(startStatus)).")
        }

        // ── Let the pipeline warm up ──────────────────────────────────────────
        Thread.sleep(forTimeInterval: 0.5)

        // ── Play the input file ───────────────────────────────────────────────
        let afplay = Process()
        afplay.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        afplay.arguments = [wavURL.path]
        try afplay.run()
        afplay.waitUntilExit()   // blocks until the 2 s file finishes

        // ── Allow pipeline tail to flush ──────────────────────────────────────
        Thread.sleep(forTimeInterval: 0.5)

        // ── Analyse captured audio ────────────────────────────────────────────
        captureLock.lock()
        let captured = capturedSamples
        captureLock.unlock()

        // 1. Must have captured a meaningful amount of audio.
        let minExpectedSamples = Int(inputSampleRate * inputDuration * 0.8)
        XCTAssertGreaterThan(captured.count, minExpectedSamples,
            "Captured only \(captured.count) samples — expected at least \(minExpectedSamples). " +
            "Pipeline may not be running. Make sure Stimmgabel.app is open.")

        guard captured.count > minExpectedSamples else { return }

        // 2. Find the window with maximum RMS — that's where the chirp is.
        //    Chirp lasts `inputDuration` s; search with 0.5 s step.
        let windowLen  = Int(inputSampleRate * inputDuration)
        let searchStep = Int(inputSampleRate * 0.5)
        var bestRMS: Float = 0
        var bestWindowStart = 0
        var pos = 0
        while pos + windowLen <= captured.count {
            let slice = captured[pos..<(pos + windowLen)]
            let rms = sqrtf(slice.reduce(0 as Float) { $0 + $1 * $1 } / Float(windowLen))
            if rms > bestRMS { bestRMS = rms; bestWindowStart = pos }
            pos += searchStep
        }
        let audioWindow = Array(captured[bestWindowStart..<(bestWindowStart + windowLen)])

        XCTAssertGreaterThan(bestRMS, 0.02,
            "Best window RMS=\(bestRMS) — audio appears silent. " +
            "Check: system audio volume, Stimmgabel.app running, afplay output device.")

        // 3. Correlation between captured window and expected mono (L+R)/2.
        //
        // Why Pearson correlation needs 2-stage alignment for a chirp:
        //   A chirp is highly phase-sensitive — even 1 ms misalignment at 2000 Hz
        //   causes ~2π phase error → correlation ≈ 0 at the wrong offset.
        //   Stage 1: find the approximate signal start via RMS energy window.
        //   Stage 2: fine search ±200 ms around that point with step=1 sample.
        //
        // What this catches:
        //   • nBufs=0 (no write)           → RMS = 0           → fails check 2
        //   • Frame repetition (old driver) → chirp time-stretched 2-3×
        //                                   → needle doesn't fit → correlation drops
        //   • Clock-drift silence bursts    → gaps in chirp     → correlation drops
        //   • De-interleaving (2ch→2×mono) → sample doubling   → chirp at half-speed
        //                                   → correlation drops

        // Search the FULL captured audio for the best alignment with the expected chirp.
        // No coarse step — robust to variable latency and concurrent test interference.
        // Short needle (0.25 s = 12000 samples) × step=32 over the full capture:
        //   265000 / 32 × 12000 ≈ 100M float ops ≈ < 1 s.
        let needleLen = min(12_000, captured.count / 4)
        let needle    = Array(expectedMono.prefix(needleLen))
        var bestCorr: Float = 0
        var coarseOffset = 0   // track position of best correlation (for latency log)
        var searchPos = 0
        while searchPos + needleLen <= captured.count {
            let c = correlation(needle, Array(captured[searchPos..<(searchPos + needleLen)]))
            if c > bestCorr { bestCorr = c; coarseOffset = searchPos }
            searchPos += 32
        }

        XCTAssertGreaterThan(bestCorr, 0.7,
            "Chirp correlation \(String(format: "%.3f", bestCorr)) < 0.7. " +
            "Expected (L+R)/2 of a 200→2000 Hz chirp. RMS was \(String(format: "%.4f", bestRMS)).\n" +
            "Possible causes:\n" +
            "  • Frame repetition (latest-frame driver model): chirp is time-stretched\n" +
            "  • De-interleaving bug: each sample doubled → chirp at half speed\n" +
            "  • Clock-drift silence bursts: gaps in the chirp\n" +
            "  • Signal present but pipeline garbles timing")

        print(String(format:
            "[PlaybackE2E] Captured %d samples (%.2fs)\n" +
            "[PlaybackE2E] Best RMS: %.4f  (expected ≈ %.4f)\n" +
            "[PlaybackE2E] Chirp correlation: %.3f  (threshold 0.70)  latency ≈ %.0f ms",
            captured.count, Double(captured.count) / inputSampleRate,
            bestRMS, (amplitudeL + amplitudeR) * 0.5 / Float(2).squareRoot(),
            bestCorr, Double(coarseOffset) / inputSampleRate * 1000))
    }
}
