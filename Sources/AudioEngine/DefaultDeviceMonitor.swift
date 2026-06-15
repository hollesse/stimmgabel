import CoreAudio
import Foundation
import os.log

private let log = OSLog(subsystem: "com.innoq.stimmgabel", category: "DefaultDeviceMonitor")

/// Append a line to ~/Library/Logs/Stimmgabel-debug.log so we can observe
/// default-device transitions without Console.app under macOS 26's
/// privacy-locked `log show`.
private func debugLog(_ message: String) {
    let fm = FileManager.default
    guard let logsDir = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs") else { return }
    try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
    let url = logsDir.appendingPathComponent("Stimmgabel-debug.log")
    let df = ISO8601DateFormatter()
    df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let line = "[\(df.string(from: Date()))] [DefaultDeviceMonitor] \(message)\n"
    if let data = line.data(using: .utf8) {
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Reads the human-readable name of the device that macOS currently considers
/// the default for the given direction.
///
/// - Parameter selector: either `kAudioHardwarePropertyDefaultInputDevice`
///   or `kAudioHardwarePropertyDefaultOutputDevice`.
/// - Returns: the device name (e.g. "MacBook Pro Microphone"), or `""` when
///   no default device exists (rare; e.g. no audio hardware connected).
public func readDefaultDeviceName(forSelector selector: AudioObjectPropertySelector) -> String {
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &addr, 0, nil, &size, &deviceID
    ) == noErr, deviceID != kAudioObjectUnknown else { return "" }

    var nameBytes = [CChar](repeating: 0, count: 256)
    var nameSize = UInt32(nameBytes.count)
    var nameAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectGetPropertyData(
        deviceID, &nameAddr, 0, nil, &nameSize, &nameBytes
    ) == noErr else { return "" }
    return String(cString: nameBytes)
}

/// Observes the macOS default input + default output device, independent of
/// any capture lifecycle. Provides their human-readable names so the menu-bar
/// dropdown can show "which mic and which output Stimmgabel will use" at all
/// times — even when no consumer is attached and no adapter is running.
///
/// Extends the property-listener pattern from ADR 0006 (mic capture) to also
/// drive UI state. Two listeners are installed on `kAudioObjectSystemObject`:
/// one for `kAudioHardwarePropertyDefaultInputDevice`, one for
/// `kAudioHardwarePropertyDefaultOutputDevice`. When either fires, the
/// monitor re-reads the corresponding device name and calls `onChange` on a
/// background queue. Callers are responsible for hopping to whatever queue
/// they need for UI updates.
///
/// HAL property-listener callbacks fire on arbitrary threads; all state
/// transitions are serialised through `queue`.
public final class DefaultDeviceMonitor: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.innoq.stimmgabel.DefaultDeviceMonitor")

    private var _micName: String = ""
    private var _sysName: String = ""

    /// Current default input device name. Empty string when no default device
    /// exists (rare — e.g. no audio hardware).
    public var currentMicDeviceName: String {
        queue.sync { _micName }
    }

    /// Current default output device name. Empty string when no default device
    /// exists (rare — e.g. no audio hardware).
    public var currentSystemAudioDeviceName: String {
        queue.sync { _sysName }
    }

    /// Fired whenever either device name changes (after the new name is
    /// already readable via `currentMicDeviceName` / `currentSystemAudioDeviceName`).
    /// May be called on an arbitrary queue.
    public var onChange: (() -> Void)?

    // Retained listener blocks so we can pass the same pointer to
    // AudioObjectRemovePropertyListenerBlock on teardown.
    private var inputListenerBlock: AudioObjectPropertyListenerBlock?
    private var outputListenerBlock: AudioObjectPropertyListenerBlock?

    private static let inputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private static let outputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    public init() {
        // Initial read so callers see the current device names immediately.
        let mic = readDefaultDeviceName(forSelector: kAudioHardwarePropertyDefaultInputDevice)
        let sys = readDefaultDeviceName(forSelector: kAudioHardwarePropertyDefaultOutputDevice)
        queue.sync {
            _micName = mic
            _sysName = sys
        }
        debugLog("init: mic=\(mic) sys=\(sys)")
        installListeners()
    }

    /// Test-friendly initializer. Skips HAL listener installation and uses
    /// the supplied names as the initial state. Use this in unit tests that
    /// must not depend on the developer Mac's current default devices.
    public init(testingMicName: String, testingSystemAudioName: String) {
        _micName = testingMicName
        _sysName = testingSystemAudioName
    }

    deinit {
        removeListeners()
    }

    private func installListeners() {
        let micBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let newName = readDefaultDeviceName(forSelector: kAudioHardwarePropertyDefaultInputDevice)
            self.queue.async {
                guard self._micName != newName else { return }
                self._micName = newName
                debugLog("default input changed → \(newName)")
                self.onChange?()
            }
        }
        let sysBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let newName = readDefaultDeviceName(forSelector: kAudioHardwarePropertyDefaultOutputDevice)
            self.queue.async {
                guard self._sysName != newName else { return }
                self._sysName = newName
                debugLog("default output changed → \(newName)")
                self.onChange?()
            }
        }

        var inputAddr = Self.inputAddress
        var outputAddr = Self.outputAddress

        let micStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &inputAddr,
            queue,
            micBlock
        )
        if micStatus == noErr {
            inputListenerBlock = micBlock
        } else {
            os_log(.error, log: log,
                   "Failed to install default-input listener: OSStatus %d", micStatus)
        }

        let sysStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &outputAddr,
            queue,
            sysBlock
        )
        if sysStatus == noErr {
            outputListenerBlock = sysBlock
        } else {
            os_log(.error, log: log,
                   "Failed to install default-output listener: OSStatus %d", sysStatus)
        }
    }

    private func removeListeners() {
        if let block = inputListenerBlock {
            var addr = Self.inputAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &addr,
                queue,
                block
            )
            inputListenerBlock = nil
        }
        if let block = outputListenerBlock {
            var addr = Self.outputAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &addr,
                queue,
                block
            )
            outputListenerBlock = nil
        }
    }

    // MARK: - Test seam

    /// Test-only: forces a re-read of both device names from the live HAL
    /// and fires `onChange` if either changed. Useful when a test wants to
    /// run against the real default devices on the developer Mac.
    public func _refreshForTesting() {
        let mic = readDefaultDeviceName(forSelector: kAudioHardwarePropertyDefaultInputDevice)
        let sys = readDefaultDeviceName(forSelector: kAudioHardwarePropertyDefaultOutputDevice)
        queue.sync {
            var changed = false
            if _micName != mic { _micName = mic; changed = true }
            if _sysName != sys { _sysName = sys; changed = true }
            if changed { onChange?() }
        }
    }

    /// Test-only: directly mutates the cached names and fires `onChange` when
    /// either name actually changes. Bypasses HAL listener wiring. Used by
    /// tests that want to assert plumbing without depending on real default
    /// devices.
    public func _setNamesForTesting(mic: String?, sys: String?) {
        queue.sync {
            var changed = false
            if let mic, _micName != mic { _micName = mic; changed = true }
            if let sys, _sysName != sys { _sysName = sys; changed = true }
            if changed { onChange?() }
        }
    }
}
