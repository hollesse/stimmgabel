import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import os.log

private let log = OSLog(subsystem: "com.innoq.stimmgabel", category: "MicAdapter")

/// Context threaded through the C-callback user-data pointer in `convertBuffer`.
/// Plain value type; safe to take an unsafe pointer to it on the stack.
private struct ConverterInputContext {
    var inputABL: UnsafePointer<AudioBufferList>
    var bytesPerFrame: UInt32   // source bytes per frame (nativeFormat.mBytesPerFrame)
    var totalFrames: UInt32     // total input frames available this IOProc call
    var consumed: UInt32        // frames already handed to the converter
}

/// Captures the macOS default microphone via the CoreAudio HAL (ADR 0006).
///
/// Resolves `kAudioHardwarePropertyDefaultInputDevice` at `start()`, registers an IOProc
/// via `AudioDeviceCreateIOProcIDWithBlock`, and calls `AudioDeviceStart`. Installs a
/// property listener on `kAudioHardwarePropertyDefaultInputDevice`; when the default input
/// changes the adapter stops the old IOProc, disposes it, and opens a new one on the new
/// device — transparently, without interrupting the mix.
///
/// # TCC / privacy
/// `AVCaptureDevice.requestAccess(for: .audio)` is called at `start()` to trigger the
/// macOS microphone permission prompt. If permission is denied `start()` throws
/// `MicAdapterError.permissionDenied` and the adapter emits silence (does not start the
/// HAL IOProc). `AVCaptureDevice.requestAccess` is the **only** AVFoundation call; actual
/// capture goes through the HAL (ADR 0006 — AVAudioEngine / AVCaptureSession rejected).
///
/// # Thread safety
/// HAL property-listener callbacks fire on arbitrary threads. All state transitions are
/// dispatched onto a single serial `DispatchQueue` owned by `MicAdapter` (ADR 0006).
///
/// # Buffer delivery
/// Buffers are delivered in the mix target format: 48 kHz / float32 / non-interleaved
/// stereo. If the mic device delivers a different sample rate or channel count an
/// `AudioConverterRef` reconciles the formats inline.
public final class MicAdapter: UpstreamCaptureAdapter, @unchecked Sendable {

    // MARK: - Public state

    public private(set) var isRunning: Bool = false
    public var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// Human-readable name of the current default input device.
    /// Updated whenever the adapter opens or rebinds to a device.
    public private(set) var deviceName: String = ""

    // MARK: - Private state

    /// Serial queue that serialises all lifecycle operations (start, stop, rebind).
    private let queue = DispatchQueue(label: "com.innoq.stimmgabel.MicAdapter")

    private var deviceID: AudioDeviceID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?

    /// Retained block reference so `AudioObjectRemovePropertyListenerBlock` receives
    /// the same function pointer it was registered with.
    private var defaultInputListenerBlock: AudioObjectPropertyListenerBlock?

    /// AudioConverterRef used for sample-rate / channel-count reconciliation. Nil when the
    /// device's native format already matches the mix target (no conversion needed).
    private var converter: AudioConverterRef?

    /// Native format delivered by the current device's IOProc. Set in `openDevice()`.
    private var nativeFormat: AudioStreamBasicDescription?

    /// Property-listener address for the default input device.
    private static let defaultInputDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    // MARK: - Mix target format

    /// 48 kHz / float32 / non-interleaved stereo — the pipeline's internal format.
    private static let mixTargetASBD: AudioStreamBasicDescription = {
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate       = 48_000
        asbd.mFormatID         = kAudioFormatLinearPCM
        asbd.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved
        asbd.mBitsPerChannel   = 32
        asbd.mChannelsPerFrame = 2
        asbd.mFramesPerPacket  = 1
        asbd.mBytesPerFrame    = 4        // sizeof(Float32)
        asbd.mBytesPerPacket   = 4
        return asbd
    }()

    private static let mixTargetAVFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    )!

    // MARK: - Init / deinit

    public init() {}

    deinit {
        if isRunning {
            tearDown()
        }
    }

    // MARK: - UpstreamCaptureAdapter

    /// Requests TCC microphone permission, resolves the current default input device,
    /// registers an IOProc on it, and installs a property listener for device changes.
    ///
    /// - Throws: `MicAdapterError.permissionDenied` when the user denies mic access.
    ///           `MicAdapterError.noDefaultInputDevice` when no default input exists.
    ///           `MicAdapterError.ioProcRegistrationFailed(status:)` on HAL failure.
    public func start() throws {
        // TCC check: if permission is already granted, proceed immediately.
        // If not yet granted (e.g. first launch), request it non-blocking so the
        // user sees the dialog; we throw permissionDenied only if already denied.
        // AppViewModel requests permission at startup so by the time a consumer
        // attaches the grant has propagated into the CoreAudio HAL — avoiding the
        // race where AudioDeviceStart hangs waiting for HAL-level TCC confirmation.
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            break  // fast path
        case .denied, .restricted:
            os_log(.error, log: log, "Microphone access denied (status %d)", status.rawValue)
            throw MicAdapterError.permissionDenied
        default:
            // notDetermined: fire-and-forget request (AppViewModel already did this;
            // if we still arrive here, throw and let the next consumer-active retry).
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            throw MicAdapterError.permissionDenied
        }

        try queue.sync {
            guard !isRunning else { return }
            try openDevice()
            installDefaultInputListener()
            isRunning = true
            os_log(.info, log: log, "MicAdapter started on device %d", deviceID)
        }
    }

    /// Stops the IOProc, disposes it, and removes the property listener.
    public func stop() {
        queue.sync {
            guard isRunning else { return }
            removeDefaultInputListener()
            tearDown()
            isRunning = false
            os_log(.info, log: log, "MicAdapter stopped")
        }
    }

    // MARK: - TCC permission

    /// Synchronously resolves AVCaptureDevice mic access.
    /// - Throws: `MicAdapterError.permissionDenied` if denied.
    private func requestMicPermission() throws {
        // Fast path: already granted.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { return }

        // If already denied or restricted, fail immediately.
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .denied || status == .restricted {
            os_log(.error, log: log, "Microphone access denied (status %d)", status.rawValue)
            throw MicAdapterError.permissionDenied
        }

        // Not determined — show the prompt synchronously using a semaphore.
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .audio) { result in
            granted = result
            semaphore.signal()
        }
        semaphore.wait()

        guard granted else {
            os_log(.error, log: log, "Microphone access denied by user")
            throw MicAdapterError.permissionDenied
        }
    }

    // MARK: - Device open / close

    private func openDevice() throws {
        let newDeviceID = try resolveDefaultInputDevice()
        deviceID = newDeviceID
        deviceName = readDeviceName(for: newDeviceID)

        // Determine the device's native stream format so we can build a converter.
        nativeFormat = try nativeInputFormat(for: newDeviceID)

        // Build an AudioConverterRef if the native format differs from the mix target.
        try buildConverterIfNeeded()

        // Register an IOProc on the device.
        try registerIOProc()
    }

    private func tearDown() {
        if let procID = ioProcID, deviceID != kAudioObjectUnknown {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
            ioProcID = nil
        }

        if let cvt = converter {
            AudioConverterDispose(cvt)
            converter = nil
        }

        nativeFormat = nil
        deviceID = kAudioObjectUnknown
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

    // MARK: - Default input device resolution

    private func resolveDefaultInputDevice() throws -> AudioDeviceID {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = MicAdapter.defaultInputDeviceAddress
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            os_log(.error, log: log,
                   "Failed to get default input device: OSStatus %d", status)
            throw MicAdapterError.noDefaultInputDevice
        }
        return deviceID
    }

    // MARK: - Native format

    private func nativeInputFormat(for device: AudioDeviceID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &asbd)
        guard status == noErr else {
            os_log(.error, log: log,
                   "Failed to read stream format for device %d: OSStatus %d", device, status)
            // Fall back to assuming a common 44.1 kHz mono layout and let the converter cope.
            var fallback = AudioStreamBasicDescription()
            fallback.mSampleRate       = 44_100
            fallback.mFormatID         = kAudioFormatLinearPCM
            fallback.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved
            fallback.mBitsPerChannel   = 32
            fallback.mChannelsPerFrame = 1
            fallback.mFramesPerPacket  = 1
            fallback.mBytesPerFrame    = 4
            fallback.mBytesPerPacket   = 4
            return fallback
        }
        return asbd
    }

    // MARK: - AudioConverterRef

    private func buildConverterIfNeeded() throws {
        guard var src = nativeFormat else { return }
        var dst = MicAdapter.mixTargetASBD

        // Only use AudioConverter for real PCM re-encoding: different sample rate, channel
        // count, or bit depth. Differences in format flags (interleaved vs. non-interleaved,
        // packed vs. unpacked) are handled manually in copyBuffer — AudioConverter is
        // unreliable for that case because macOS reports inconsistent mBytesPerFrame values
        // for non-interleaved USB devices, causing packet-count mismatches in the input proc.
        let needsHardwareConversion =
            src.mSampleRate != dst.mSampleRate ||
            src.mChannelsPerFrame != dst.mChannelsPerFrame ||
            src.mBitsPerChannel != dst.mBitsPerChannel

        guard needsHardwareConversion else {
            converter = nil
            return
        }

        var cvt: AudioConverterRef?
        let status = AudioConverterNew(&src, &dst, &cvt)
        guard status == noErr, let cvt else {
            os_log(.error, log: log,
                   "AudioConverterNew failed: OSStatus %d", status)
            converter = nil
            return
        }
        converter = cvt
        os_log(.info, log: log,
               "AudioConverter created: %.0f Hz %d ch → 48000 Hz 2 ch",
               src.mSampleRate, src.mChannelsPerFrame)
    }

    // MARK: - IOProc registration

    private func registerIOProc() throws {
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) {
            [weak self] _, inInputData, inInputTime, _, _ in
            guard let self else { return }
            self.handleIOProc(inputData: inInputData, inputTime: inInputTime)
        }

        guard status == noErr, let procID else {
            os_log(.error, log: log,
                   "AudioDeviceCreateIOProcIDWithBlock failed: OSStatus %d", status)
            throw MicAdapterError.ioProcRegistrationFailed(status: status)
        }
        self.ioProcID = procID

        let startStatus = AudioDeviceStart(deviceID, procID)
        guard startStatus == noErr else {
            os_log(.error, log: log,
                   "AudioDeviceStart failed: OSStatus %d", startStatus)
            AudioDeviceDestroyIOProcID(deviceID, procID)
            self.ioProcID = nil
            throw MicAdapterError.ioProcRegistrationFailed(status: startStatus)
        }
        _ioProcCallCount = 0
        os_log(.info, log: log, "AudioDeviceStart OK on device %d — waiting for IOProc callbacks", deviceID)
    }

    // MARK: - IOProc callback

    private var _ioProcCallCount: Int = 0

    private func handleIOProc(
        inputData: UnsafePointer<AudioBufferList>,
        inputTime: UnsafePointer<AudioTimeStamp>
    ) {
        _ioProcCallCount += 1

        guard let handler = onBuffer else {
            if _ioProcCallCount == 1 {
                os_log(.error, log: log, "IOProc fired but onBuffer is nil — audio will not reach pipeline")
            }
            return
        }

        let abl = inputData.pointee
        guard abl.mNumberBuffers > 0 else {
            if _ioProcCallCount <= 3 {
                os_log(.error, log: log, "IOProc: mNumberBuffers=0, no audio delivered")
            }
            return
        }

        let firstBuffer = withUnsafePointer(to: abl.mBuffers) { $0.pointee }
        // Frame count depends on the delivery layout:
        //  • Non-interleaved (mNumberBuffers > 1 or kAudioFormatFlagIsNonInterleaved):
        //    each buffer holds one channel → frameCount = mDataByteSize / sizeof(Float32)
        //  • Interleaved (mNumberBuffers == 1, no non-interleaved flag):
        //    one buffer holds all channels → frameCount = mDataByteSize / (channels × 4)
        let bytesPerSample = UInt32(MemoryLayout<Float32>.size)  // 4
        let isNonInterleaved: Bool
        if abl.mNumberBuffers > 1 {
            isNonInterleaved = true
        } else if let flags = nativeFormat?.mFormatFlags {
            isNonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
        } else {
            isNonInterleaved = false
        }
        let channels = max(nativeFormat?.mChannelsPerFrame ?? 1, 1)
        let frameCount: UInt32
        if isNonInterleaved {
            frameCount = firstBuffer.mDataByteSize / bytesPerSample
        } else {
            frameCount = firstBuffer.mDataByteSize / (bytesPerSample * channels)
        }
        guard frameCount > 0 else { return }

        // For a rate-converting converter the output frame count differs from the input.
        // E.g. AirPods deliver 24 kHz; mix target is 48 kHz → 480 input → 960 output frames.
        // ioOutputDataPacketSize passed to AudioConverterFillComplexBuffer must be in OUTPUT frames.
        let srcRate = nativeFormat?.mSampleRate ?? 48_000
        let outputFrameCount: UInt32
        if converter != nil, srcRate > 0, srcRate != 48_000 {
            outputFrameCount = UInt32((Double(frameCount) * 48_000.0 / srcRate).rounded())
        } else {
            outputFrameCount = frameCount
        }
        guard outputFrameCount > 0 else { return }

        // Build an output buffer in the mix target format.
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: MicAdapter.mixTargetAVFormat,
            frameCapacity: AVAudioFrameCount(outputFrameCount)
        ) else { return }
        outputBuffer.frameLength = AVAudioFrameCount(outputFrameCount)

        if let cvt = converter, var src = nativeFormat {
            // Convert to mix target format; pass the OUTPUT frame count.
            convertBuffer(
                converter: cvt,
                inputABL: inputData,
                nativeFormat: &src,
                outputFrameCount: outputFrameCount,
                into: outputBuffer
            )
        } else {
            // Native format matches or conversion is unavailable — copy directly.
            copyBuffer(from: abl, frameCount: frameCount, into: outputBuffer)
        }

        // Diagnostic: log every 100th IOProc call so we can see if audio is flowing.
        if _ioProcCallCount % 100 == 1 {
            let peak: Float
            if let ch0 = outputBuffer.floatChannelData?[0] {
                peak = (0..<Int(outputBuffer.frameLength)).reduce(0.0) { max($0, abs(ch0[$1])) }
            } else {
                peak = 0
            }
            os_log(.info, log: log, "IOProc #%d: frameLength=%d peak=%.4f (0=silence)",
                   _ioProcCallCount, outputBuffer.frameLength, peak)
        }

        handler(outputBuffer)
    }

    /// Copies raw float32 data from an input `AudioBufferList` into an `AVAudioPCMBuffer`.
    /// Handles both non-interleaved (multiple buffers) and interleaved (single buffer) input,
    /// and mono→stereo duplication. No sample-rate conversion.
    private func copyBuffer(
        from abl: AudioBufferList,
        frameCount: UInt32,
        into output: AVAudioPCMBuffer
    ) {
        let bytesPerSample = UInt32(MemoryLayout<Float32>.size)

        withUnsafeMutablePointer(to: &output.mutableAudioBufferList.pointee) { ablPtr in
            let ablBuffers = UnsafeMutableAudioBufferListPointer(ablPtr)

            if abl.mNumberBuffers > 1 {
                // Non-interleaved: each source buffer = one channel.
                let channelCount = min(Int(abl.mNumberBuffers), 2)
                for ch in 0..<channelCount {
                    let srcBuf = audioBuffer(from: abl, at: ch)
                    if let dst = ablBuffers[ch].mData?.assumingMemoryBound(to: Float32.self),
                       let src = srcBuf.mData?.assumingMemoryBound(to: Float32.self) {
                        let frames = Int(min(frameCount, srcBuf.mDataByteSize / bytesPerSample))
                        dst.update(from: src, count: frames)
                    }
                }
                // Mono → stereo: duplicate left to right.
                if abl.mNumberBuffers == 1,
                   let left  = ablBuffers[0].mData?.assumingMemoryBound(to: Float32.self),
                   let right = ablBuffers[1].mData?.assumingMemoryBound(to: Float32.self) {
                    right.update(from: left, count: Int(frameCount))
                }
            } else {
                // Interleaved: one buffer with all channels interleaved L R L R …
                // Deinterleave into the output (non-interleaved).
                let srcBuf = audioBuffer(from: abl, at: 0)
                guard let src = srcBuf.mData?.assumingMemoryBound(to: Float32.self) else { return }
                let srcChannels = Int(nativeFormat?.mChannelsPerFrame ?? 1)
                let frames = Int(frameCount)

                if srcChannels >= 2,
                   let dstL = ablBuffers[0].mData?.assumingMemoryBound(to: Float32.self),
                   let dstR = ablBuffers[1].mData?.assumingMemoryBound(to: Float32.self) {
                    // Deinterleave stereo.
                    for i in 0..<frames {
                        dstL[i] = src[i * srcChannels]
                        dstR[i] = src[i * srcChannels + 1]
                    }
                } else if let dstL = ablBuffers[0].mData?.assumingMemoryBound(to: Float32.self),
                          let dstR = ablBuffers[1].mData?.assumingMemoryBound(to: Float32.self) {
                    // Mono → stereo: copy mono samples to both channels.
                    for i in 0..<frames {
                        dstL[i] = src[i]
                        dstR[i] = src[i]
                    }
                }
            }
        }
    }

    /// Runs the `AudioConverterRef` to resample / reformat into the mix target `AVAudioPCMBuffer`.
    /// `outputFrameCount` must be in the converter's output domain (48 kHz), not input domain.
    private func convertBuffer(
        converter: AudioConverterRef,
        inputABL: UnsafePointer<AudioBufferList>,
        nativeFormat: inout AudioStreamBasicDescription,
        outputFrameCount: UInt32,
        into output: AVAudioPCMBuffer
    ) {
        let bpf = max(nativeFormat.mBytesPerFrame, 1)
        var ctx = ConverterInputContext(
            inputABL: inputABL,
            bytesPerFrame: bpf,
            totalFrames: inputABL.pointee.mBuffers.mDataByteSize / bpf,
            consumed: 0
        )
        var ioOutputDataPacketSize = outputFrameCount

        withUnsafeMutablePointer(to: &output.mutableAudioBufferList.pointee) { outABL in
            withUnsafeMutablePointer(to: &ctx) { ctxPtr in
                AudioConverterFillComplexBuffer(
                    converter,
                    { _, ioDataPackets, ioData, _, userData in
                        guard let ud = userData else { return kAudioConverterErr_UnspecifiedError }
                        let ctx = ud.assumingMemoryBound(to: ConverterInputContext.self)

                        let remaining = ctx.pointee.totalFrames - ctx.pointee.consumed
                        guard remaining > 0 else {
                            ioDataPackets.pointee = 0
                            return noErr
                        }

                        let requested = ioDataPackets.pointee
                        let providing = min(requested, remaining)
                        let byteOff = Int(ctx.pointee.consumed * ctx.pointee.bytesPerFrame)

                        // Fill each input buffer starting at the current read offset.
                        let srcABL = ctx.pointee.inputABL.pointee
                        let numBufs = min(Int(ioData.pointee.mNumberBuffers),
                                         Int(srcABL.mNumberBuffers))
                        let dstBufs = UnsafeMutableAudioBufferListPointer(ioData)
                        withUnsafePointer(to: srcABL.mBuffers) { srcBufBase in
                            for i in 0..<numBufs {
                                var buf = srcBufBase.advanced(by: i).pointee
                                if let base = buf.mData {
                                    buf.mData = base.advanced(by: byteOff)
                                }
                                buf.mDataByteSize = providing * ctx.pointee.bytesPerFrame
                                dstBufs[i] = buf
                            }
                        }
                        ioData.pointee.mNumberBuffers = UInt32(numBufs)

                        ioDataPackets.pointee = providing
                        ctx.pointee.consumed += providing
                        return noErr
                    },
                    UnsafeMutableRawPointer(ctxPtr),
                    &ioOutputDataPacketSize,
                    outABL,
                    nil
                )
            }
        }
    }

    /// Unsafe helper to index into a fixed-size AudioBufferList.
    private func audioBuffer(from abl: AudioBufferList, at index: Int) -> AudioBuffer {
        withUnsafePointer(to: abl.mBuffers) { ptr in
            ptr.advanced(by: index).pointee
        }
    }

    // MARK: - Default-input device change listener

    private func installDefaultInputListener() {
        var address = MicAdapter.defaultInputDeviceAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultInputDeviceChanged()
        }
        defaultInputListenerBlock = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            nil,
            block
        )
        if status != noErr {
            os_log(.error, log: log,
                   "Failed to install default-input listener: OSStatus %d", status)
        }
    }

    private func removeDefaultInputListener() {
        guard let block = defaultInputListenerBlock else { return }
        var address = MicAdapter.defaultInputDeviceAddress
        let status = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            nil,
            block
        )
        defaultInputListenerBlock = nil
        if status != noErr {
            os_log(.debug, log: log,
                   "removeDefaultInputListener: OSStatus %d", status)
        }
    }

    private func handleDefaultInputDeviceChanged() {
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            os_log(.info, log: log, "Default input device changed — rebinding IOProc")
            self.tearDown()
            do {
                try self.openDevice()
                os_log(.info, log: log, "MicAdapter rebound to new default input device %d",
                       self.deviceID)
            } catch {
                os_log(.error, log: log,
                       "Failed to rebind after default input change: %{public}@",
                       String(describing: error))
                // Deliver silence: the adapter remains "running" but has no IOProc.
                // The next default-device change will trigger another rebind attempt.
            }
        }
    }
}

// MARK: - Errors

public enum MicAdapterError: Error, Equatable {
    case permissionDenied
    case noDefaultInputDevice
    case ioProcRegistrationFailed(status: OSStatus)
}
