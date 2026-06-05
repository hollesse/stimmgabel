import AVFAudio
import CoreAudio
import Foundation
import os.log

private let log = OSLog(subsystem: "com.innoq.stimmgabel", category: "SystemAudioAdapter")

/// Captures all system audio via the CoreAudio Process Tap API (ADR 0004).
///
/// Creates a global `CATapDescription` (empty process list, captures all audio on the
/// default output device) and wraps it in an aggregate device so it presents as a
/// standard `AudioDeviceID`. Rebinds automatically when the macOS default output device
/// changes. Delivers buffers in the mix target format (48 kHz / float32 / non-interleaved
/// stereo) via the `onBuffer` handler.
///
/// Minimum macOS: 14.2 (API availability); 14.4 recommended (stability floor per ADR 0004).
///
/// # Sandbox note
/// `AudioHardwareCreateProcessTap` is unconfirmed inside the App Sandbox. v1 runs
/// unsandboxed. If the API fails (OSStatus != noErr), a clear log message is emitted and
/// `start()` throws `SystemAudioAdapterError.tapCreationFailed`.
@available(macOS 14.2, *)
public final class SystemAudioAdapter: UpstreamCaptureAdapter, @unchecked Sendable {

    // MARK: - Public state

    public private(set) var isRunning: Bool = false
    public var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    // MARK: - Private state

    /// Serial queue that serialises all lifecycle operations (create, destroy, rebind).
    private let queue = DispatchQueue(label: "com.innoq.stimmgabel.SystemAudioAdapter")

    private var tapObjectID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?

    /// The device the aggregate wraps; tracked so we can rebind on change.
    private var currentOutputDeviceID: AudioDeviceID = kAudioObjectUnknown

    /// Retained reference to the property-listener block so we can pass the same
    /// pointer to `AudioObjectRemovePropertyListenerBlock` on teardown.
    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?

    /// Property-listener address for the default output device.
    private static let defaultOutputDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    // MARK: - Target format

    /// Mix target format: 48 kHz / float32 / non-interleaved stereo.
    private static let mixTargetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    )!

    // MARK: - Init / deinit

    public init() {}

    deinit {
        // Attempt a best-effort cleanup if the adapter is still running.
        if isRunning {
            tearDown()
        }
    }

    // MARK: - UpstreamCaptureAdapter

    /// Creates the Process Tap, wraps it in an aggregate device, and registers an IOProc.
    /// Installs a property listener for default-output-device changes.
    /// Throws `SystemAudioAdapterError` on failure.
    public func start() throws {
        try queue.sync {
            guard !isRunning else { return }
            try setUp()
            installDefaultOutputListener()
            isRunning = true
            os_log(.info, log: log, "SystemAudioAdapter started on device %d", aggregateDeviceID)
        }
    }

    /// Tears down the IOProc, aggregate device, and tap. Removes the property listener.
    public func stop() {
        queue.sync {
            guard isRunning else { return }
            removeDefaultOutputListener()
            tearDown()
            isRunning = false
            os_log(.info, log: log, "SystemAudioAdapter stopped")
        }
    }

    // MARK: - Setup / teardown

    private func setUp() throws {
        // 1. Find the current default output device.
        let defaultOutputDevice = try currentDefaultOutputDevice()
        currentOutputDeviceID = defaultOutputDevice

        // 2. Create the Process Tap.
        tapObjectID = try createTap(boundToOutputDevice: defaultOutputDevice)

        // 3. Wrap the tap in an aggregate device.
        aggregateDeviceID = try createAggregateDevice(tapObjectID: tapObjectID)

        // 4. Register the IOProc on the aggregate device.
        try registerIOProc()
    }

    private func tearDown() {
        // Stop and unregister IOProc first.
        if let procID = ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            ioProcID = nil
        }

        // Destroy aggregate device.
        if aggregateDeviceID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if status != noErr {
                os_log(.error, log: log,
                       "AudioHardwareDestroyAggregateDevice failed: %d", status)
            }
            aggregateDeviceID = kAudioObjectUnknown
        }

        // Destroy tap.
        if tapObjectID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyProcessTap(tapObjectID)
            if status != noErr {
                os_log(.error, log: log,
                       "AudioHardwareDestroyProcessTap failed: %d", status)
            }
            tapObjectID = kAudioObjectUnknown
        }

        currentOutputDeviceID = kAudioObjectUnknown
    }

    // MARK: - Process Tap creation

    private func currentDefaultOutputDevice() throws -> AudioDeviceID {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = SystemAudioAdapter.defaultOutputDeviceAddress
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            os_log(.error, log: log,
                   "Failed to get default output device: OSStatus %d", status)
            throw SystemAudioAdapterError.noDefaultOutputDevice
        }
        return deviceID
    }

    private func createTap(boundToOutputDevice outputDeviceID: AudioDeviceID) throws -> AudioObjectID {
        // CATapDescription: stereo global tap, excludes no processes (captures everything).
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])

        var tapObjectID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(tapDescription, &tapObjectID)
        guard status == noErr, tapObjectID != kAudioObjectUnknown else {
            os_log(.error, log: log,
                   "AudioHardwareCreateProcessTap failed: OSStatus %d", status)
            throw SystemAudioAdapterError.tapCreationFailed(status: status)
        }
        os_log(.info, log: log,
               "Process Tap created: objectID=%d bound to outputDevice=%d",
               tapObjectID, outputDeviceID)
        return tapObjectID
    }

    // MARK: - Aggregate device creation

    private func createAggregateDevice(tapObjectID: AudioObjectID) throws -> AudioDeviceID {
        // Build the UID string for the tap sub-device.
        guard let tapUID = tapUID(for: tapObjectID) else {
            os_log(.error, log: log, "Could not read UID for tap %d", tapObjectID)
            throw SystemAudioAdapterError.aggregateDeviceCreationFailed(status: -1)
        }

        // Sub-device list: just the tap.
        let tapSubDevice: [CFString: Any] = [
            kAudioSubDeviceUIDKey as CFString: tapUID
        ]

        // Tap list entry.
        let tapEntry: [CFString: Any] = [
            kAudioSubTapUIDKey as CFString: tapUID
        ]

        let description: [CFString: Any] = [
            kAudioAggregateDeviceNameKey as CFString:
                "Stimmgabel System Audio" as CFString,
            kAudioAggregateDeviceUIDKey as CFString:
                "com.innoq.stimmgabel.systemAudioAggregate" as CFString,
            kAudioAggregateDeviceSubDeviceListKey as CFString:
                [tapSubDevice] as CFArray,
            kAudioAggregateDeviceTapListKey as CFString:
                [tapEntry] as CFArray,
            kAudioAggregateDeviceTapAutoStartKey as CFString: true as CFBoolean,
            kAudioAggregateDeviceIsPrivateKey as CFString: true as CFBoolean,
        ]

        var aggregateID = AudioDeviceID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(
            description as CFDictionary,
            &aggregateID
        )
        guard status == noErr, aggregateID != kAudioObjectUnknown else {
            os_log(.error, log: log,
                   "AudioHardwareCreateAggregateDevice failed: OSStatus %d", status)
            throw SystemAudioAdapterError.aggregateDeviceCreationFailed(status: status)
        }
        os_log(.info, log: log,
               "Aggregate device created: deviceID=%d", aggregateID)
        return aggregateID
    }

    private func tapUID(for tapObjectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            tapObjectID, &address,
            0, nil,
            &size, &uid
        )
        guard status == noErr, let result = uid else { return nil }
        return result.takeRetainedValue() as String
    }

    // MARK: - IOProc registration

    private func registerIOProc() throws {
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, nil) {
            [weak self] inNow, inInputData, inInputTime, outOutputData, inOutputTime in
            guard let self else { return }
            self.handleIOProc(inputData: inInputData, inputTime: inInputTime)
        }

        guard status == noErr, let procID else {
            os_log(.error, log: log,
                   "AudioDeviceCreateIOProcIDWithBlock failed: OSStatus %d", status)
            throw SystemAudioAdapterError.ioProcRegistrationFailed(status: status)
        }
        self.ioProcID = procID

        let startStatus = AudioDeviceStart(aggregateDeviceID, procID)
        guard startStatus == noErr else {
            os_log(.error, log: log,
                   "AudioDeviceStart failed: OSStatus %d", startStatus)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            self.ioProcID = nil
            throw SystemAudioAdapterError.ioProcRegistrationFailed(status: startStatus)
        }
    }

    // MARK: - IOProc callback

    private func handleIOProc(
        inputData: UnsafePointer<AudioBufferList>,
        inputTime: UnsafePointer<AudioTimeStamp>
    ) {
        guard let handler = onBuffer else { return }

        let abl = inputData.pointee
        guard abl.mNumberBuffers > 0 else { return }

        // Determine frame count from the first buffer.
        let firstBuffer = abl.mBuffers
        let bytesPerFrame = UInt32(MemoryLayout<Float32>.size)
        let frameCount = firstBuffer.mDataByteSize / bytesPerFrame

        guard frameCount > 0 else { return }

        // Build an AVAudioPCMBuffer in the mix target format.
        let format = SystemAudioAdapter.mixTargetFormat
        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        // Copy channel data from the input AudioBufferList.
        // The Process Tap delivers interleaved or non-interleaved depending on the device;
        // we map it to non-interleaved float32. Channel 0 = left, channel 1 = right.
        let channelCount = min(Int(abl.mNumberBuffers), 2)
        withUnsafeMutablePointer(to: &pcmBuffer.mutableAudioBufferList.pointee) { ablPtr in
            let ablBuffers = UnsafeMutableAudioBufferListPointer(ablPtr)
            for ch in 0..<channelCount {
                let srcBuf = audioBuffer(from: abl, at: ch)
                if let dst = ablBuffers[ch].mData?.assumingMemoryBound(to: Float32.self),
                   let src = srcBuf.mData?.assumingMemoryBound(to: Float32.self) {
                    let framesToCopy = Int(min(frameCount, srcBuf.mDataByteSize / bytesPerFrame))
                    dst.update(from: src, count: framesToCopy)
                }
            }
            // If mono input, duplicate left channel to right.
            if channelCount == 1,
               let left = ablBuffers[0].mData?.assumingMemoryBound(to: Float32.self),
               let right = ablBuffers[1].mData?.assumingMemoryBound(to: Float32.self) {
                right.update(from: left, count: Int(frameCount))
            }
        }

        handler(pcmBuffer)
    }

    /// Unsafe helper to index into a fixed-size AudioBufferList.
    private func audioBuffer(from abl: AudioBufferList, at index: Int) -> AudioBuffer {
        return withUnsafePointer(to: abl.mBuffers) { ptr in
            ptr.advanced(by: index).pointee
        }
    }

    // MARK: - Default-output device change listener

    private func installDefaultOutputListener() {
        var address = SystemAudioAdapter.defaultOutputDeviceAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultOutputDeviceChanged()
        }
        defaultOutputListenerBlock = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            nil,
            block
        )
        if status != noErr {
            os_log(.error, log: log,
                   "Failed to install default-output listener: OSStatus %d", status)
        }
    }

    private func removeDefaultOutputListener() {
        guard let block = defaultOutputListenerBlock else { return }
        var address = SystemAudioAdapter.defaultOutputDeviceAddress
        let status = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            nil,
            block
        )
        defaultOutputListenerBlock = nil
        if status != noErr {
            os_log(.debug, log: log,
                   "removeDefaultOutputListener: OSStatus %d", status)
        }
    }

    private func handleDefaultOutputDeviceChanged() {
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            os_log(.info, log: log, "Default output device changed — rebinding tap")
            self.tearDown()
            do {
                try self.setUp()
                os_log(.info, log: log, "Tap rebound to new default output device")
            } catch {
                os_log(.error, log: log,
                       "Failed to rebind tap after default output change: %{public}@",
                       String(describing: error))
            }
        }
    }
}

// MARK: - Errors

public enum SystemAudioAdapterError: Error, Equatable {
    case noDefaultOutputDevice
    case tapCreationFailed(status: OSStatus)
    case aggregateDeviceCreationFailed(status: OSStatus)
    case ioProcRegistrationFailed(status: OSStatus)
}
