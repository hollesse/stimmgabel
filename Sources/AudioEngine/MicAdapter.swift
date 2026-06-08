import AVFAudio
import Foundation
import os.log

private let log = OSLog(subsystem: "com.innoq.stimmgabel", category: "MicAdapter")

/// Captures microphone audio using AVAudioEngine.
///
/// Uses `AVAudioEngine.inputNode.installTap` instead of direct HAL APIs.
/// This avoids the macOS 26 `AudioDeviceStart` ETIMEDOUT (0x3C) deadlock
/// that occurs when the mic device is started concurrently with the system-audio
/// Process Tap aggregate device.
///
/// AVAudioEngine handles TCC permission, device changes, and format conversion
/// internally.  The tap delivers 48 kHz / float32 / non-interleaved stereo
/// buffers matching the mix target format expected by AudioPipeline.
public final class MicAdapter: UpstreamCaptureAdapter, @unchecked Sendable {

    // MARK: - UpstreamCaptureAdapter

    public private(set) var isRunning = false
    public var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    public private(set) var deviceName = ""

    // MARK: - Private

    private let engine = AVAudioEngine()
    private let queue  = DispatchQueue(label: "com.innoq.stimmgabel.MicAdapter")

    private static let mixTargetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    )!

    public init() {}
    deinit { if isRunning { stop() } }

    // MARK: - UpstreamCaptureAdapter

    public func start() throws {
        try queue.sync {
            guard !isRunning else { return }
            let inputNode = engine.inputNode

            // installTap with the mix target format: CoreAudio performs any necessary
            // sample-rate conversion and channel expansion (mono→stereo) internally.
            inputNode.installTap(
                onBus: 0,
                bufferSize: 512,
                format: MicAdapter.mixTargetFormat
            ) { [weak self] buffer, _ in
                guard let self, let handler = self.onBuffer else { return }
                handler(buffer)
            }

            try engine.start()

            deviceName = Self.readDefaultInputDeviceName()
            isRunning  = true
            os_log(.info, log: log, "MicAdapter started via AVAudioEngine (device: %{public}@)", deviceName)
        }
    }

    public func stop() {
        queue.sync {
            guard isRunning else { return }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRunning  = false
            deviceName = ""
            os_log(.info, log: log, "MicAdapter stopped")
        }
    }

    // MARK: - Helpers

    private static func readDefaultInputDeviceName() -> String {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size     = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address  = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return "" }

        var nameBytes = [CChar](repeating: 0, count: 256)
        var nameSize  = UInt32(nameBytes.count)
        var nameAddr  = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceName,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            deviceID, &nameAddr, 0, nil, &nameSize, &nameBytes
        ) == noErr else { return "" }
        return String(cString: nameBytes)
    }
}
