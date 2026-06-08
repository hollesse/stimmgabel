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

    /// Human-readable name of the current default output device (the source of system audio).
    /// Updated whenever the adapter opens or rebinds to a device.
    public private(set) var deviceName: String = ""

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

    // MARK: - Resampler

    /// Resamples IOProc data to `mixTargetFormat` when the aggregate runs at a different rate.
    /// Nil when the aggregate already delivers 48 kHz (no conversion needed).
    private var converter: AVAudioConverter?
    /// Input format matching what the aggregate IOProc actually delivers.
    private var inputFormat: AVAudioFormat?

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
        deviceName = readDeviceName(for: defaultOutputDevice)

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
        deviceName = ""
    }

    // MARK: - Device name

    private func readDeviceName(for device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameBytes = [CChar](repeating: 0, count: 256)
        var size = UInt32(nameBytes.count)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &nameBytes)
        guard status == noErr else { return "" }
        return String(cString: nameBytes)
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

        // Query the actual native sample rate — do NOT force 48 kHz; the tap delivers
        // at the system output rate and forcing 48 kHz breaks the tap data flow.
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var actualRate: Float64 = 48_000
        var sz = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(aggregateID, &rateAddr, 0, nil, &sz, &actualRate)

        os_log(.info, log: log,
               "Aggregate device created: deviceID=%d sampleRate=%.0f Hz",
               aggregateID, actualRate)
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

        // Build a resampler if the aggregate runs at something other than 48 kHz.
        // The IOProc delivers interleaved stereo; we resample to non-interleaved 48 kHz.
        setupConverter(for: aggregateDeviceID)
    }

    private func setupConverter(for deviceID: AudioDeviceID) {
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 48_000
        var sz = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(deviceID, &rateAddr, 0, nil, &sz, &rate)

        // IOProc delivers interleaved stereo at `rate` Hz.
        let src = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: rate,
                                channels: 2,
                                interleaved: true)!
        inputFormat = src

        if rate != 48_000 {
            converter = AVAudioConverter(from: src, to: SystemAudioAdapter.mixTargetFormat)
            os_log(.info, log: log,
                   "Resampler created: %.0f Hz interleaved → 48000 Hz non-interleaved", rate)
        } else {
            converter = nil
            os_log(.info, log: log, "No resampling needed: tap already at 48000 Hz")
        }
    }

    // MARK: - IOProc callback

    private var didLogFormat = false

    private func handleIOProc(
        inputData: UnsafePointer<AudioBufferList>,
        inputTime: UnsafePointer<AudioTimeStamp>
    ) {
        guard let handler = onBuffer else { return }

        let abl = inputData.pointee
        guard abl.mNumberBuffers > 0 else { return }

        let firstBuf      = abl.mBuffers
        let nInBufs       = Int(abl.mNumberBuffers)
        let nInChPerBuf   = Int(max(firstBuf.mNumberChannels, 1))
        let bytesPerFrame = UInt32(MemoryLayout<Float32>.size) * firstBuf.mNumberChannels
        let frameCount    = bytesPerFrame > 0 ? Int(firstBuf.mDataByteSize / bytesPerFrame) : 0
        guard frameCount > 0 else { return }

        if !didLogFormat {
            didLogFormat = true
            os_log(.info, log: log,
                   "IOProc format: nBufs=%d nChPerBuf=%d dataByteSize=%d → frameCount=%d",
                   nInBufs, nInChPerBuf, firstBuf.mDataByteSize, frameCount)
        }

        // --- Wrap raw input bytes into an AVAudioPCMBuffer ---
        // The tap delivers interleaved stereo; build a buffer pointing at the same memory.
        guard let fmt = inputFormat,
              let rawBuf = AVAudioPCMBuffer(pcmFormat: fmt,
                                            frameCapacity: AVAudioFrameCount(frameCount))
        else { return }
        rawBuf.frameLength = AVAudioFrameCount(frameCount)

        // Copy interleaved samples into rawBuf's single channel buffer.
        if let dst = rawBuf.int16ChannelData {
            _ = dst  // unused — just ensure it's interleaved
        }
        // For interleaved format the buffer is accessed via audioBufferList.
        guard let srcPtr = firstBuf.mData else { return }
        rawBuf.mutableAudioBufferList.pointee.mNumberBuffers = 1
        rawBuf.mutableAudioBufferList.pointee.mBuffers.mData = srcPtr
        rawBuf.mutableAudioBufferList.pointee.mBuffers.mDataByteSize = firstBuf.mDataByteSize
        rawBuf.mutableAudioBufferList.pointee.mBuffers.mNumberChannels = firstBuf.mNumberChannels

        // --- Convert / resample to 48 kHz non-interleaved stereo ---
        if let conv = converter {
            let outFrames = AVAudioFrameCount(
                Double(frameCount) * 48_000.0 / fmt.sampleRate + 0.5
            )
            guard let outBuf = AVAudioPCMBuffer(
                pcmFormat: SystemAudioAdapter.mixTargetFormat,
                frameCapacity: outFrames
            ) else { return }

            var convError: NSError?
            conv.convert(to: outBuf, error: &convError) { _, outStatus in
                outStatus.pointee = .haveData
                return rawBuf
            }
            if convError == nil && outBuf.frameLength > 0 {
                handler(outBuf)
            }
        } else {
            // Already 48 kHz — de-interleave directly into the mix-target buffer.
            guard let outBuf = AVAudioPCMBuffer(
                pcmFormat: SystemAudioAdapter.mixTargetFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
            ) else { return }
            outBuf.frameLength = AVAudioFrameCount(frameCount)

            let left  = outBuf.floatChannelData![0]
            let right = outBuf.floatChannelData![1]

            if nInBufs == 1 && nInChPerBuf >= 2,
               let src = firstBuf.mData?.assumingMemoryBound(to: Float32.self) {
                for i in 0..<frameCount {
                    left[i]  = src[i * nInChPerBuf]
                    right[i] = src[i * nInChPerBuf + 1]
                }
            } else if let srcL = firstBuf.mData?.assumingMemoryBound(to: Float32.self) {
                left.update(from: srcL, count: frameCount)
                if nInBufs >= 2,
                   let srcR = audioBuffer(from: abl, at: 1).mData?.assumingMemoryBound(to: Float32.self) {
                    right.update(from: srcR, count: frameCount)
                } else {
                    right.update(from: srcL, count: frameCount)
                }
            }
            handler(outBuf)
        }
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
