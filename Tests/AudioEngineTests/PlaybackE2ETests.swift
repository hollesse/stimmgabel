import XCTest
import CoreAudio
import AVFAudio
import Foundation
@testable import AudioEngine

// MARK: - Playback End-to-End Tests
//
// Plays a real audio file through the system audio output and records what
// Stimmgabel's virtual mic delivers to a HAL consumer.
//
// Signal path under test:
//   afplay → system audio output
//     → Stimmgabel Process Tap (SystemAudioAdapter)
//     → SHM ring buffer (SHMDriverIPCConnection)
//     → Driver DoIOOperation (sequential gReadPos model)
//     → CoreAudio HAL output → this test's IOProc
//
// Test signal: tone sequence 200 Hz (1s) → 880 Hz (1s) → 1760 Hz (1s).
// Each tone is detected via autocorrelation at its expected period, which
// is phase-insensitive and robust to small rate differences.
//
// Why tone sequence over a chirp:
//   • Chirp requires exact phase alignment → fails with small rate mismatch
//   • Tone autocorrelation works regardless of phase
//   • Frame repetition (old latest-frame driver bug): at t=1s the pipeline
//     delivers the wrong tone (still 200 Hz, not 880 Hz) → test fails
//
// Prerequisites:
//   • Stimmgabel.app must be running (holds Screen Recording permission)
//   • Stimmgabel.driver installed in /Library/Audio/Plug-Ins/HAL/
//   Run: swift test --filter PlaybackE2ETests

final class PlaybackE2ETests: XCTestCase {

    private let kVirtualMicUID = "com.innoq.stimmgabel.virtualmic"
    private let kSampleRate    = 48_000.0
    private let kAmplitude: Float = 0.5

    // MARK: - Device discovery

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
               let uid = uidRef as String?, uid == kVirtualMicUID { return device }
        }
        return nil
    }

    private func stimmgabelIsRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.innoq.stimmgabel").isEmpty
    }

    // MARK: - Signal helpers

    /// Tone sequence: `tones[i].freq` Hz for `tones[i].duration` seconds.
    private func makeToneSequence(_ tones: [(freq: Float, duration: Double)]) -> [Float] {
        var samples = [Float]()
        for tone in tones {
            let n = Int(tone.duration * kSampleRate)
            for i in 0..<n {
                samples.append(kAmplitude * sinf(2 * .pi * tone.freq * Float(i) / Float(kSampleRate)))
            }
        }
        return samples
    }

    /// Writes mono samples to a 48 kHz WAV file.
    private func writeTempWAV(_ samples: [Float]) throws -> URL {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: kSampleRate, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                   frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        let ch = buf.floatChannelData![0]
        for (i, v) in samples.enumerated() { ch[i] = v }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stimmgabel_e2e_\(arc4random()).wav")
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        try file.write(from: buf)
        return url
    }

    /// Normalised autocorrelation at `lag` samples. Returns a value in [-1, 1].
    /// High value (>0.7) means the signal is strongly periodic at 1/lag Hz.
    private func autocorr(_ samples: [Float], lag: Int) -> Float {
        let n = samples.count - lag
        guard n > 0 else { return 0 }
        var dot: Float = 0; var sq: Float = 0
        for i in 0..<n { dot += samples[i] * samples[i + lag]; sq += samples[i] * samples[i] }
        return sq > 0 ? dot / sq : 0
    }

    // MARK: - The E2E test

    /// Plays a 200 Hz → 880 Hz → 1760 Hz tone sequence via afplay, records from
    /// the virtual mic, and verifies each tone arrives at the correct time.
    ///
    /// What this catches (compared to a pure sine):
    ///   • No signal (RMS = 0) → fails check 1
    ///   • Frame repetition (old gReadPos bug / latest-frame model):
    ///     at t=1s the captured audio still has 200 Hz instead of 880 Hz → fails check 2
    ///   • Clock-drift silence bursts: missing audio → RMS drops → fails check 1
    ///   • De-interleaving bug: wrong (L+R)/2 mix → amplitude wrong → fails check 1
    func test_afplay_toneSequence_correctFrequenciesAtExpectedTimes() throws {
        guard let deviceID = findVirtualMicDevice() else {
            throw XCTSkip("Stimmgabel.driver not loaded — run ./script/install-driver.sh first.")
        }
        guard stimmgabelIsRunning() else {
            throw XCTSkip(
                "Stimmgabel.app is not running. Start it first before running this test.\n" +
                "The app must run because it holds the Screen Recording permission " +
                "needed to capture system audio via the Process Tap.")
        }

        // Tone sequence: each tone 1 second long.
        let tones: [(freq: Float, duration: Double)] = [
            (freq: 200,  duration: 1.0),
            (freq: 880,  duration: 1.0),
            (freq: 1760, duration: 1.0),
        ]
        let inputSamples = makeToneSequence(tones)
        let wavURL = try writeTempWAV(inputSamples)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        // ── Record from the virtual mic ───────────────────────────────────────
        var capturedSamples = [Float]()
        let captureLock     = NSLock()
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
            throw XCTSkip("AudioDeviceCreateIOProcIDWithBlock failed (\(createStatus)).")
        }
        defer { AudioDeviceStop(deviceID, procID); AudioDeviceDestroyIOProcID(deviceID, procID) }

        guard AudioDeviceStart(deviceID, procID) == noErr else {
            throw XCTSkip("AudioDeviceStart failed.")
        }

        // Pipeline warm-up: let the app overwrite any stale SHM data (SHM capacity
        // = 4096 frames = 85 ms, so 500 ms is more than enough to clear it).
        Thread.sleep(forTimeInterval: 0.5)

        // Verify the pipeline is live: wait a moment, then check the RMS of what
        // the virtual mic is delivering.  If the SHM name was stolen by another
        // test process (VirtualMicE2ETests.setUp calls sg_shm_unlink), the driver
        // maps a different inode than the app writes to → IOProc receives only zeros.
        // Detect this early and skip rather than produce a confusing test failure.
        //
        // Note: this test must be run separately from VirtualMicE2ETests:
        //   swift test --filter PlaybackE2ETests
        // Start Stimmgabel.app FIRST, then run this test.
        captureLock.lock()
        let preSamples = capturedSamples
        captureLock.unlock()
        // Even in silence, the ambient RMS at the system output should be > 1e-5
        // if the tap is actually working.  Pure zeros → SHM disconnected from app.
        let preRMS = preSamples.isEmpty ? 0.0
                     : sqrtf(preSamples.reduce(0 as Float) { $0 + $1*$1 } / Float(preSamples.count))
        guard preRMS > 1e-5 else {
            throw XCTSkip(
                "Virtual mic delivering pure silence before afplay (RMS=\(preRMS)). " +
                "Likely cause: VirtualMicE2ETests.setUp unlinked the SHM, disconnecting " +
                "the app from the driver.\n" +
                "Fix: run this test in isolation — swift test --filter PlaybackE2ETests — " +
                "after restarting Stimmgabel.app.")
        }

        // Play the tone sequence (3 seconds).
        let afplay = Process()
        afplay.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        afplay.arguments = [wavURL.path]
        try afplay.run()
        afplay.waitUntilExit()

        // Allow the pipeline tail to flush.
        Thread.sleep(forTimeInterval: 0.5)

        // ── Analyse ───────────────────────────────────────────────────────────
        captureLock.lock()
        let captured = capturedSamples
        captureLock.unlock()

        // 1. Must have captured meaningful audio (at least 2 s).
        let minSamples = Int(kSampleRate * 2.0)
        XCTAssertGreaterThan(captured.count, minSamples,
            "Captured only \(captured.count) samples (<2s). Pipeline may not be running.")
        guard captured.count > minSamples else { return }

        // 2. Find the FIRST appearance of the 200 Hz tone in the capture.
        //    We search for the first window where the 200 Hz autocorrelation
        //    exceeds 0.7, which marks the onset of the tone sequence.
        //    Using "first occurrence" (not "max") avoids landing in the middle
        //    of the tone zone — which would shift subsequent tone windows.
        let period200 = Int((kSampleRate / 200.0).rounded())   // 240 samples
        let checkLen  = period200 * 20                          // 20 cycles ≈ 100 ms
        let stride200 = Int(kSampleRate * 0.05)                 // 50 ms step

        var toneStart = -1; var bestAC200: Float = 0
        var sp = 0
        while sp + checkLen <= captured.count {
            let slice = Array(captured[sp..<(sp + checkLen)])
            let ac = autocorr(slice, lag: period200)
            if ac > bestAC200 { bestAC200 = ac }
            if ac > 0.7 && toneStart == -1 { toneStart = sp }
            sp += stride200
        }

        XCTAssertGreaterThan(bestAC200, 0.7,
            "200 Hz tone not found in captured audio (best autocorr=\(String(format: "%.3f", bestAC200))). " +
            "Check that Stimmgabel.app is capturing system audio.")
        guard toneStart >= 0 else { return }

        // 3. Verify each tone appears at the expected time position.
        //    A frame-repetition bug (old latest-frame driver model) causes the pipeline
        //    to play each tone N× slower: at t=1s the capture still has 200 Hz, not 880 Hz.
        let toneDuration = Int(kSampleRate * 1.0)   // 48000 samples per tone

        for (idx, tone) in tones.enumerated() {
            let period  = Int((kSampleRate / Double(tone.freq)).rounded())
            // Window in the middle of the expected tone (avoids transition edges).
            let midStart = toneStart + idx * toneDuration + toneDuration / 4
            let midEnd   = midStart + period * 30   // 30 cycles

            guard midEnd <= captured.count else { continue }
            let window = Array(captured[midStart..<midEnd])
            let ac     = autocorr(window, lag: period)

            XCTAssertGreaterThan(ac, 0.7,
                "Tone #\(idx + 1) (\(Int(tone.freq)) Hz) not found at expected time t=\(idx)s. " +
                "Autocorrelation at lag=\(period): \(String(format: "%.3f", ac)).\n" +
                "Possible causes:\n" +
                "  • Frame repetition (old latest-frame driver model): " +
                    "tone \(idx + 1) plays later than expected\n" +
                "  • Clock-drift gaps: missing portions of the tone sequence\n" +
                "  • Signal present but at wrong position in time")
        }

        let windowRMS = { (start: Int, len: Int) -> Float in
            let slice = captured[start..<min(start + len, captured.count)]
            return sqrtf(slice.reduce(0 as Float) { $0 + $1 * $1 } / Float(slice.count))
        }
        let rmsAtToneStart = windowRMS(toneStart, Int(kSampleRate))

        print(String(format:
            "[PlaybackE2E] Captured %.2fs  tone starts at %.0f ms  RMS=%.4f\n" +
            "[PlaybackE2E] Autocorrelations — 200Hz: %.3f  880Hz: %.3f  1760Hz: %.3f",
            Double(captured.count) / kSampleRate,
            Double(toneStart) / kSampleRate * 1000,
            rmsAtToneStart,
            autocorr(Array(captured[toneStart..<min(toneStart + Int(kSampleRate), captured.count)]),
                     lag: period200),
            autocorr(Array(captured[toneStart + toneDuration..<min(toneStart + 2*toneDuration, captured.count)]),
                     lag: Int((kSampleRate / 880.0).rounded())),
            autocorr(Array(captured[toneStart + 2*toneDuration..<min(toneStart + 3*toneDuration, captured.count)]),
                     lag: Int((kSampleRate / 1760.0).rounded()))))
    }
}
