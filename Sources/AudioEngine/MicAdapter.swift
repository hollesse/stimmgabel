import AVFAudio
import Foundation
import os.log

private let log = OSLog(subsystem: "com.innoq.stimmgabel", category: "MicAdapter")

/// Captures microphone audio using AVAudioEngine.
///
/// The engine is started eagerly in `init()` so the 2-second AVAudioEngine
/// initialization cost is paid once at app launch, not on every consumer
/// attach.  While no consumer is active the tap fires but callbacks are
/// no-ops; once `start()` is called data flows to `onBuffer` immediately.
///
/// The mic indicator in the macOS menu bar (orange dot) becomes visible when
/// the app launches, which is expected for a "virtual microphone" application.
public final class MicAdapter: UpstreamCaptureAdapter, @unchecked Sendable {

    // MARK: - UpstreamCaptureAdapter

    public private(set) var isRunning = false
    public var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    public private(set) var deviceName = ""

    // MARK: - Private

    private let engine = AVAudioEngine()
    private let lock   = NSLock()

    private static let mixTargetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    )!

    // MARK: - Init

    public init() {
        // Install the tap immediately so the engine graph is configured.
        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: 512,
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

        // Pre-start: pays the 2-second coreaudiod init cost at app launch.
        // Errors (e.g. permission not yet granted) are ignored here — the
        // engine will be started again in start() once permission is granted.
        if (try? engine.start()) != nil {
            deviceName = Self.readDefaultInputDeviceName()
            os_log(.info, log: log, "MicAdapter pre-started (device: %{public}@)", deviceName)
        }
    }

    deinit {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    // MARK: - UpstreamCaptureAdapter

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard !isRunning else { return }

        // Start or restart the engine if it stopped (e.g. interrupted by permission dialog).
        if !engine.isRunning {
            try engine.start()
            deviceName = Self.readDefaultInputDeviceName()
            os_log(.info, log: log, "MicAdapter engine started (device: %{public}@)", deviceName)
        }

        isRunning = true
        os_log(.info, log: log, "MicAdapter active")
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard isRunning else { return }
        isRunning = false
        os_log(.info, log: log, "MicAdapter inactive (engine keeps running)")
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
