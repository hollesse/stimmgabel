import XCTest
import CoreAudio
import AVFAudio
import DriverIPC
@testable import AudioEngine

// MARK: - Virtual Mic End-to-End Tests
//
// These tests open the Stimmgabel virtual microphone device via the CoreAudio
// HAL — exactly like Audacity, Handy, or any other recording app — and verify
// that audio written by the pipeline actually arrives at the consumer.
//
// What is uniquely tested here:
//   • The complete path: FakeAdapter → Pipeline → SHM → Driver DoIOOperation → HAL IOProc
//   • Real CoreAudio device enumeration (driver must be installed)
//   • Consumer-active Darwin notify delivery end-to-end
//   • Non-silence confirmation at the consumer side
//
// Prerequisites:
//   • Stimmgabel.driver installed in /Library/Audio/Plug-Ins/HAL/
//   • Stimmgabel.app NOT running (would compete for the consumer-active notify)
//   Run: ./script/install-driver.sh  before running these tests.

final class VirtualMicE2ETests: XCTestCase {

    private let kVirtualMicUID = "com.innoq.stimmgabel.virtualmic"

    // MARK: - Device discovery

    private func findVirtualMicDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return nil }

        var devices = [AudioDeviceID](repeating: 0,
                                      count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices) == noErr
        else { return nil }

        for device in devices {
            var uidRef: CFString? = nil
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            if AudioObjectGetPropertyData(device, &uidAddr, 0, nil, &uidSize, &uidRef) == noErr,
               let uid = uidRef as String?,
               uid == kVirtualMicUID {
                return device
            }
        }
        return nil
    }

    // MARK: - Helpers

    private func makeSineBuffer(frames: Int = 960,
                                 amplitude: Float = 0.5,
                                 freq: Float = 440) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: 48_000, channels: 2, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                   frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        let ch0 = buf.floatChannelData![0]
        let ch1 = buf.floatChannelData![1]
        for i in 0..<frames {
            let v = amplitude * sinf(2 * .pi * freq * Float(i) / 48_000)
            ch0[i] = v; ch1[i] = v
        }
        return buf
    }

    // MARK: - setUp / tearDown

    override func setUp() {
        super.setUp()
        // Unlink stale SHM from a previous crashed test — recreated by SHMDriverIPCConnection.connect().
        // We do NOT unlink in tearDown so the running Stimmgabel.app can keep using the segment.
        sg_shm_unlink(SG_SHM_NAME)
    }

    // MARK: - 1. Virtual mic is discoverable

    func test_virtualMicDevice_isEnumeratedByCoreAudio() throws {
        guard findVirtualMicDevice() != nil else {
            throw XCTSkip(
                "Stimmgabel.driver not loaded. " +
                "Run ./script/install-driver.sh and restart coreaudiod, then re-run.")
        }
        // If we reach here the device exists — pass.
    }

    // MARK: - 2. Virtual mic delivers non-silent audio when pipeline writes a sine

    func test_virtualMic_deliversNonSilentAudio_whenPipelineWritesSine() throws {
        guard let deviceID = findVirtualMicDevice() else {
            throw XCTSkip("Stimmgabel.driver not loaded — see test_virtualMicDevice_isEnumeratedByCoreAudio")
        }

        // ── Pipeline with real SHM ─────────────────────────────────────────
        let sys = FakeUpstreamCaptureAdapter()
        let pipeline = AudioPipeline(systemAudioAdapter: sys)
        let shmConn  = SHMDriverIPCConnection()
        let adapter  = DriverOutputAdapter(pipeline: pipeline, ipc: shmConn)

        Thread.sleep(forTimeInterval: 0.1)   // wait for async openSHM()

        // ── IOProc on the Stimmgabel virtual mic ───────────────────────────
        // Peak amplitude received by the HAL consumer (this is what Audacity/Handy sees).
        var capturedPeak: Float = 0.0
        let gotAudio = DispatchSemaphore(value: 0)
        var signaled = false
        var ioProcCallCount = 0

        var ioProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID, deviceID, nil
        ) { _, inInputData, _, _, _ in
            ioProcCallCount += 1
            withUnsafePointer(to: inInputData.pointee.mBuffers) { bp in
                guard let ptr = bp.pointee.mData?.assumingMemoryBound(to: Float.self),
                      bp.pointee.mDataByteSize > 0 else { return }
                let count = Int(bp.pointee.mDataByteSize) / MemoryLayout<Float>.size
                for i in 0..<count {
                    let v = abs(ptr[i])
                    if v > capturedPeak { capturedPeak = v }
                }
            }
            if capturedPeak > 0.01 && !signaled {
                signaled = true
                gotAudio.signal()
            }
        }

        guard createStatus == noErr, let procID = ioProcID else {
            throw XCTSkip(
                "AudioDeviceCreateIOProcIDWithBlock failed (status=\(createStatus)). " +
                "Possible cause: driver process sandboxed or device missing.")
        }
        defer {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }

        // Start recording — triggers driver StartIO → consumer-active notify.
        let startStatus = AudioDeviceStart(deviceID, procID)
        XCTAssertEqual(startStatus, noErr,
            "AudioDeviceStart on virtual mic failed (status=\(startStatus)). " +
            "Driver may not be installed correctly.")

        // Wait for consumer-active to reach our SHMDriverIPCConnection.
        Thread.sleep(forTimeInterval: 0.3)
        adapter.syncBarrier()

        // Inject a 440 Hz sine wave — this is what should reach the IOProc.
        sys.emitBuffer(makeSineBuffer(frames: 960, amplitude: 0.5))

        // Wait up to 3 s for the signal to propagate:
        //   render tick (≤11 ms) → SHM write → driver DoIOOperation → HAL → our block
        let result = gotAudio.wait(timeout: .now() + 3.0)

        XCTAssertEqual(result, .success,
            "TIMEOUT: Virtual mic delivered only silence for 3 seconds after a " +
            "440 Hz sine at amplitude 0.5 was written to the pipeline. " +
            "Expected peak > 0.01 at the HAL consumer. Got peak=\(capturedPeak). " +
            "IOProc was called \(ioProcCallCount) times. " +
            "Possible causes: " +
            "(1) IOProc never called (AudioDeviceStart did not activate IO), " +
            "(2) consumer-active notify not received by SHMDriverIPCConnection, " +
            "(3) render timer not writing to SHM, " +
            "(4) driver DoIOOperation reading zeros (writePos issue).")

        XCTAssertGreaterThan(capturedPeak, 0.01,
            "Audio reached the IOProc but peak=\(capturedPeak) is below 0.01. " +
            "Signal may be attenuated in the pipeline or driver.")
    }

    // MARK: - 3. Virtual mic delivers silence when pipeline is muted

    func test_virtualMic_deliversSilence_whenBothSidesMuted() throws {
        guard let deviceID = findVirtualMicDevice() else {
            throw XCTSkip("Stimmgabel.driver not loaded")
        }

        let sys = FakeUpstreamCaptureAdapter()
        let pipeline = AudioPipeline(systemAudioAdapter: sys)
        let shmConn  = SHMDriverIPCConnection()
        let adapter  = DriverOutputAdapter(pipeline: pipeline, ipc: shmConn)

        Thread.sleep(forTimeInterval: 0.1)

        var capturedPeak: Float = 0.0
        var ioProcID: AudioDeviceIOProcID?
        AudioDeviceCreateIOProcIDWithBlock(&ioProcID, deviceID, nil) { _, inInputData, _, _, _ in
            withUnsafePointer(to: inInputData.pointee.mBuffers) { bp in
                guard let ptr = bp.pointee.mData?.assumingMemoryBound(to: Float.self),
                      bp.pointee.mDataByteSize > 0 else { return }
                let count = Int(bp.pointee.mDataByteSize) / MemoryLayout<Float>.size
                for i in 0..<count { let v = abs(ptr[i]); if v > capturedPeak { capturedPeak = v } }
            }
        }
        guard let procID = ioProcID else { return }
        defer { AudioDeviceStop(deviceID, procID); AudioDeviceDestroyIOProcID(deviceID, procID) }

        AudioDeviceStart(deviceID, procID)
        Thread.sleep(forTimeInterval: 0.3)
        adapter.syncBarrier()

        // No buffer emitted — pipeline delivers silence.
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertLessThan(capturedPeak, 0.01,
            "No audio emitted but virtual mic peak=\(capturedPeak) > 0.01. " +
            "Pipeline should deliver silence when no upstream buffer is available.")
    }
}
