import AVFAudio
import CoreAudio
import Foundation
import os.log

private let log = OSLog(subsystem: "com.innoq.stimmgabel", category: "SystemAudioAdapter")

/// Captures system audio AND microphone in a single CoreAudio aggregate device.
///
/// The aggregate contains:
///   - A CATapDescription (process tap) that captures the default output device
///   - The default input device (microphone) as a sub-device and master clock
///
/// Using a single aggregate avoids the macOS 26 IOWorkLoop 0x3C ETIMEDOUT that
/// occurs when two separate AudioDeviceStart calls run concurrently.  The mic
/// indicator in the macOS menu bar appears only while a consumer is recording.
///
/// The IOProc delivers combined channels (tap + mic).  `handleIOProc` extracts
/// them, mixes them (sys_L + mic, sys_R + mic), and calls `onBuffer` with a
/// 48 kHz / float32 / non-interleaved stereo buffer.
///
/// Minimum macOS: 14.2 (API availability); 14.4 recommended (stability floor).
///
/// # Sandbox note
/// `AudioHardwareCreateProcessTap` is unconfirmed inside the App Sandbox.  v1 runs
/// unsandboxed.  If the API fails (OSStatus != noErr), a clear log message is emitted
/// and `start()` throws `SystemAudioAdapterError.tapCreationFailed`.
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

    /// The output device the tap is bound to; tracked so we can rebind on change.
    private var currentOutputDeviceID: AudioDeviceID = kAudioObjectUnknown
    /// The input device (microphone) included in the aggregate.
    private var currentInputDeviceID: AudioDeviceID  = kAudioObjectUnknown
    /// Number of tap (system-audio) channels in the IOProc ABL.
    /// Determined on the first IOProc call and used for channel splitting.
    private var tapChannelCount: Int = 2

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
        // 1. Find the current default output and input devices.
        let defaultOutputDevice = try currentDefaultOutputDevice()
        currentOutputDeviceID = defaultOutputDevice
        deviceName = readDeviceName(for: defaultOutputDevice)

        currentInputDeviceID = (try? currentDefaultInputDevice()) ?? kAudioObjectUnknown
        tapChannelCount = 2   // reset; determined on first IOProc call

        // 2. Create the Process Tap.
        tapObjectID = try createTap(boundToOutputDevice: defaultOutputDevice)

        // 3. Wrap tap + mic in a single aggregate device.
        aggregateDeviceID = try createAggregateDevice(tapObjectID: tapObjectID,
                                                       micDeviceID: currentInputDeviceID)

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

    // MARK: - Default-input device helper

    private func currentDefaultInputDevice() throws -> AudioDeviceID {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size     = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address  = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else {
            throw SystemAudioAdapterError.noDefaultOutputDevice
        }
        return deviceID
    }

    private func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var uid: Unmanaged<CFString>?
        var size    = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid) == noErr,
              let result = uid else { return nil }
        return result.takeRetainedValue() as String
    }

    // MARK: - Aggregate device creation

    private func createAggregateDevice(tapObjectID: AudioObjectID,
                                        micDeviceID: AudioDeviceID) throws -> AudioDeviceID {
        guard let tapUID = tapUID(for: tapObjectID) else {
            os_log(.error, log: log, "Could not read UID for tap %d", tapObjectID)
            throw SystemAudioAdapterError.aggregateDeviceCreationFailed(status: -1)
        }

        // Tap sub-device: needs drift compensation because it has no hardware clock.
        let tapSubDevice: [CFString: Any] = [
            kAudioSubDeviceUIDKey as CFString:          tapUID,
            kAudioSubDeviceDriftCompensationKey as CFString: true as CFBoolean,
        ]

        // Tap list entry.
        let tapEntry: [CFString: Any] = [kAudioSubTapUIDKey as CFString: tapUID]

        // Microphone sub-device (optional — gracefully degrade to tap-only if unavailable).
        let micUID    = micDeviceID != kAudioObjectUnknown ? deviceUID(for: micDeviceID) : nil
        let hasMic    = micUID != nil
        let micSubDev: [CFString: Any] = [kAudioSubDeviceUIDKey as CFString: micUID ?? ""]

        // Sub-device list: tap first, then mic.
        // With mic as master clock the IOProc delivers tap channels first, then mic.
        var subDeviceList: [[CFString: Any]] = [tapSubDevice]
        if hasMic { subDeviceList.append(micSubDev) }

        var description: [CFString: Any] = [
            kAudioAggregateDeviceNameKey as CFString:
                "Stimmgabel" as CFString,
            kAudioAggregateDeviceUIDKey as CFString:
                "com.innoq.stimmgabel.systemAudioAggregate" as CFString,
            kAudioAggregateDeviceSubDeviceListKey as CFString: subDeviceList as CFArray,
            kAudioAggregateDeviceTapListKey as CFString:       [tapEntry] as CFArray,
            kAudioAggregateDeviceTapAutoStartKey as CFString:  true as CFBoolean,
            kAudioAggregateDeviceIsPrivateKey as CFString:     true as CFBoolean,
        ]
        // Mic drives the master clock; tap follows via drift compensation.
        if hasMic {
            description[kAudioAggregateDeviceMainSubDeviceKey as CFString] = micUID!
        }
        let logMic = hasMic ? micUID! : "none"
        os_log(.info, log: log, "Creating aggregate: tap=%{public}@ mic=%{public}@", tapUID, logMic)

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
        // The new handleIOProc writes directly to the output buffer without a
        // separate AVAudioConverter; just log the rate for diagnostics.
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 48_000
        var sz = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(deviceID, &rateAddr, 0, nil, &sz, &rate)
        os_log(.info, log: log, "Aggregate sample rate: %.0f Hz", rate)
        converter  = nil
        inputFormat = nil
    }

    // MARK: - IOProc callback

    private var didLogFormat = false

    private func handleIOProc(
        inputData: UnsafePointer<AudioBufferList>,
        inputTime: UnsafePointer<AudioTimeStamp>
    ) {
        guard let handler = onBuffer else { return }

        let abl    = inputData.pointee
        guard abl.mNumberBuffers > 0 else { return }

        let firstBuf      = abl.mBuffers
        let nInBufs       = Int(abl.mNumberBuffers)
        let nInChPerBuf   = Int(max(firstBuf.mNumberChannels, 1))
        let bytesPerFrame = UInt32(MemoryLayout<Float32>.size) * firstBuf.mNumberChannels
        let frameCount    = bytesPerFrame > 0 ? Int(firstBuf.mDataByteSize / bytesPerFrame) : 0
        guard frameCount > 0 else { return }

        // Log format on first call and detect tap/mic channel split.
        if !didLogFormat {
            didLogFormat = true
            var info = "IOProc: nBufs=\(nInBufs)"
            for i in 0..<min(nInBufs, 4) {
                let b = audioBuffer(from: abl, at: i)
                info += " buf[\(i)]: nCh=\(b.mNumberChannels) bytes=\(b.mDataByteSize)"
            }
            os_log(.info, log: log, "%{public}@", info)

            // Determine how many channels belong to the tap.
            // If mic is in the aggregate the total channel count > 2.
            // Tap channels = total - mic channels (mic is mono = 1 ch).
            let totalChannels = nInBufs == 1 ? nInChPerBuf
                              : (0..<nInBufs).reduce(0) { $0 + Int(audioBuffer(from: abl, at: $1).mNumberChannels) }
            tapChannelCount = currentInputDeviceID != kAudioObjectUnknown
                            ? max(2, totalChannels - 1)   // at least 2 tap channels
                            : totalChannels
            os_log(.info, log: log,
                   "Channel split: total=%d tap=%d mic=%d",
                   totalChannels, tapChannelCount, totalChannels - tapChannelCount)
        }

        // Extract sys-audio samples (channels 0..tapChannelCount-1) and
        // mic sample (channel tapChannelCount, if present).
        guard let outBuf = AVAudioPCMBuffer(
            pcmFormat: SystemAudioAdapter.mixTargetFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else { return }
        outBuf.frameLength = AVAudioFrameCount(frameCount)

        let outL = outBuf.floatChannelData![0]
        let outR = outBuf.floatChannelData![1]
        let nTot = nInBufs == 1 ? nInChPerBuf : nInBufs   // effective channels

        if nInBufs == 1,
           let src = firstBuf.mData?.assumingMemoryBound(to: Float32.self) {
            // Single interleaved buffer: channels are [ch0, ch1, ch2, ...] per frame.
            let micOffset = tapChannelCount  // 0-based index of mic channel
            for i in 0..<frameCount {
                let base = i * nTot
                let tapL = nTot > 0 ? src[base + 0] : 0
                let tapR = nTot > 1 ? src[base + 1] : tapL
                let mic  = nTot > micOffset ? src[base + micOffset] : 0
                outL[i] = tapL + mic
                outR[i] = tapR + mic
            }
        } else {
            // Non-interleaved or multi-buffer: each AudioBuffer is one channel.
            func ptr(_ idx: Int) -> UnsafePointer<Float32>? {
                guard idx < nInBufs else { return nil }
                return audioBuffer(from: abl, at: idx).mData.map {
                    UnsafeRawPointer($0).assumingMemoryBound(to: Float32.self)
                }
            }
            let tapL = ptr(0)
            let tapR = nInBufs > 1 ? ptr(1) : tapL
            let mic  = ptr(tapChannelCount)
            for i in 0..<frameCount {
                let m = mic?[i] ?? 0
                outL[i] = (tapL?[i] ?? 0) + m
                outR[i] = (tapR?[i] ?? 0) + m
            }
        }

        handler(outBuf)
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
