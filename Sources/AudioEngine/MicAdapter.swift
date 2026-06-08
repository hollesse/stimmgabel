import AVFAudio
import Foundation
import os.log

private let log = OSLog(subsystem: "com.innoq.stimmgabel", category: "MicAdapter")

/// Captures microphone audio using AVAudioEngine.
///
/// The engine is started lazily — only when `start()` is called (i.e. when a consumer
/// attaches to the virtual mic).  It is stopped when `stop()` is called (consumer
/// detaches), so the macOS mic indicator (orange dot) is only visible while recording.
///
/// AudioPipeline starts the mic adapter in the background (not blocking sys audio startup),
/// so the consumer hears system audio immediately; mic audio joins ~1–2 s later.
public final class MicAdapter: UpstreamCaptureAdapter, @unchecked Sendable {

    public private(set) var isRunning = false
    public var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    public private(set) var deviceName = ""

    private let engine = AVAudioEngine()
    private let lock   = NSLock()

    private static let mixTargetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000, channels: 2, interleaved: false)!

    public init() {
        // Install the tap now so the engine graph is configured, but do NOT start.
        // Starting is deferred to start() so the mic indicator only shows while recording.
        engine.inputNode.installTap(
            onBus: 0, bufferSize: 512,
            format: MicAdapter.mixTargetFormat
        ) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock()
            let running = self.isRunning
            let handler = self.onBuffer
            self.lock.unlock()
            guard running, let handler else { return }
            handler(buffer)
        }
    }

    deinit {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard !isRunning else { return }
        if !engine.isRunning { try engine.start() }
        deviceName = Self.readDefaultInputDeviceName()
        isRunning  = true
        os_log(.info, log: log, "MicAdapter started (%{public}@)", deviceName)
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard isRunning else { return }
        isRunning = false
        engine.stop()   // stops the IO thread → mic indicator disappears
        deviceName = ""
        os_log(.info, log: log, "MicAdapter stopped")
    }

    private static func readDefaultInputDeviceName() -> String {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return "" }
        var nameBytes = [CChar](repeating: 0, count: 256)
        var nameSize = UInt32(nameBytes.count)
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, &nameBytes) == noErr
        else { return "" }
        return String(cString: nameBytes)
    }
}
