import AudioEngineBridge
import AVFoundation
import AVFAudio
import Foundation
import os.log

private let log = OSLog(subsystem: "com.innoq.stimmgabel", category: "MicAdapter")

/// Append a line to ~/Library/Logs/Stimmgabel-debug.log so we can see what's
/// happening without macOS 26's privacy-locked `log show`.
private func debugLog(_ message: String) {
    let fm = FileManager.default
    guard let logsDir = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs") else { return }
    try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
    let url = logsDir.appendingPathComponent("Stimmgabel-debug.log")
    let df = ISO8601DateFormatter()
    df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let line = "[\(df.string(from: Date()))] \(message)\n"
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

    private var engine = AVAudioEngine()
    private let lock   = NSLock()
    private var tapInstalled = false
    private var callbackCount = 0
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?

    private static let mixTargetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000, channels: 2, interleaved: false)!

    public init() {
        // No hardware access. AVAudioEngine.inputNode.installTap cannot be called
        // during SwiftUI's initial @StateObject render (the XPC channel to coreaudiod
        // is not yet ready at that point with .window-style MenuBarExtra).
        // Tap installation is deferred to start(), which runs after the app's run loop
        // is fully established and a consumer has attached.
    }

    deinit {
        if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        engine.stop()
    }

    /// Call once at app launch so macOS shows the permission dialog early.
    public static func requestPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    /// Pre-install the tap at app launch (deferred) so consumer-attach only pays
    /// the engine.start() cost (~400ms) instead of also the installTap cost (~450ms).
    /// installTap alone does NOT activate the mic indicator — only engine.start does.
    /// Safe to call multiple times.
    public func prepare() {
        // Defer to next runloop tick so SwiftUI's @StateObject init is fully done
        // before we touch AVAudioEngine's XPC channel to coreaudiod.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                debugLog("prepare() skipped — permission not authorized")
                return
            }
            self.lock.lock()
            let alreadyDone = self.tapInstalled
            self.lock.unlock()
            if alreadyDone { return }
            self.installTapIfNeeded()
        }
    }

    /// Installs the tap on the main thread, with retry on transient coreaudiod failures.
    /// Updates `tapInstalled` accordingly. Idempotent.
    private func installTapIfNeeded() {
        lock.lock()
        if tapInstalled { lock.unlock(); return }
        lock.unlock()

        var tapOk = false
        let install: () -> Void = { [weak self] in
            guard let self else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            let tapError = SGTryInstallTap(
                self.engine.inputNode, 0, 512,
                nil
            ) { [weak self] buffer, _ in
                guard let self else { return }
                let n = self.callbackCount
                self.callbackCount = n + 1
                if n == 0 {
                    os_log(.info, log: log,
                           "MicAdapter first callback: fmt=%{public}@ frames=%d ch=%d interleaved=%d",
                           buffer.format.description,
                           buffer.frameLength,
                           buffer.format.channelCount,
                           buffer.format.isInterleaved ? 1 : 0)
                    debugLog("FIRST MIC CALLBACK: fmt=\(buffer.format.description) frames=\(buffer.frameLength) ch=\(buffer.format.channelCount) interleaved=\(buffer.format.isInterleaved)")
                }
                if n % 100 == 0 {
                    let peak = (0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs(buffer.floatChannelData?[0][$1] ?? 0)) }
                    debugLog("mic callback #\(n): peak=\(peak)")
                }
                self.lock.lock()
                let running = self.isRunning
                let handler = self.onBuffer
                self.lock.unlock()
                guard running, let handler else { return }
                if let converted = self.convert(buffer) {
                    handler(converted)
                }
            }
            if let reason = tapError {
                debugLog("installTap FAILED: \(reason)")
                os_log(.error, log: log, "MicAdapter installTap failed: %{public}@", reason)
            } else {
                tapOk = true
                debugLog("installTap OK")
            }
        }
        if Thread.isMainThread { install() } else { DispatchQueue.main.sync(execute: install) }

        if !tapOk {
            // Retry once with a fresh engine — clears any stale per-engine state.
            let retry: () -> Void = { [weak self] in
                guard let self else { return }
                self.engine = AVAudioEngine()
                let tapError2 = SGTryInstallTap(
                    self.engine.inputNode, 0, 512,
                    nil
                ) { [weak self] buffer, _ in
                    guard let self else { return }
                    self.lock.lock()
                    let running = self.isRunning
                    let handler = self.onBuffer
                    self.lock.unlock()
                    guard running, let handler else { return }
                    if let converted = self.convert(buffer) {
                        handler(converted)
                    }
                }
                if let reason = tapError2 {
                    debugLog("installTap RETRY FAILED: \(reason)")
                } else {
                    tapOk = true
                    debugLog("installTap RETRY OK")
                }
            }
            if Thread.isMainThread { retry() } else { DispatchQueue.main.sync(execute: retry) }
        }

        lock.lock()
        tapInstalled = tapOk
        lock.unlock()
    }

    public func start() throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        debugLog("start() called — permission status: \(status.rawValue) (authorized=\(status == .authorized ? "YES" : "NO"))")
        guard status == .authorized else {
            os_log(.error, log: log, "MicAdapter: mic permission denied — skipping")
            debugLog("start() ABORTED: permission not authorized")
            return
        }

        lock.lock()
        if isRunning { lock.unlock(); debugLog("start() noop: already running"); return }
        let needTap = !tapInstalled
        lock.unlock()

        if needTap {
            debugLog("start() installing tap on demand (prepare() was not called or failed)")
            installTapIfNeeded()
            lock.lock()
            let ok = tapInstalled
            lock.unlock()
            guard ok else { debugLog("start() ABORTED after tap install failure"); return }
        }

        debugLog("calling engine.start() (isRunning=\(engine.isRunning))")
        do {
            if !engine.isRunning { try engine.start() }
            debugLog("engine.start() returned OK")
        } catch {
            debugLog("engine.start() THREW: \(error)")
            throw error
        }
        lock.lock()
        deviceName = readDefaultDeviceName(forSelector: kAudioHardwarePropertyDefaultInputDevice)
        isRunning = true
        lock.unlock()
        os_log(.info, log: log, "MicAdapter started (%{public}@)", deviceName)
        debugLog("MicAdapter started — device=\(deviceName)")
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard isRunning else { return }
        isRunning = false
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        deviceName = ""
        os_log(.info, log: log, "MicAdapter stopped")
    }

    /// Convert a buffer from the mic's native format to `mixTargetFormat`
    /// (48kHz stereo float32 non-interleaved). Mono mics get duplicated to both
    /// channels. Sample rates other than 48kHz get resampled. Returns nil on
    /// converter failure. Builds the converter lazily on first call.
    private func convert(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let target = MicAdapter.mixTargetFormat
        let sourceFormat = source.format

        // Fast path: already in the target format.
        if sourceFormat.sampleRate == target.sampleRate &&
           sourceFormat.channelCount == target.channelCount &&
           sourceFormat.commonFormat == target.commonFormat &&
           sourceFormat.isInterleaved == target.isInterleaved {
            return source
        }

        if converter == nil || converterSourceFormat != sourceFormat {
            converter = AVAudioConverter(from: sourceFormat, to: target)
            converterSourceFormat = sourceFormat
            debugLog("MicAdapter: built converter from \(sourceFormat) → \(target)")
        }
        guard let conv = converter else { return nil }

        let ratio = target.sampleRate / sourceFormat.sampleRate
        let outFrames = AVAudioFrameCount(Double(source.frameLength) * ratio + 0.5)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outFrames) else { return nil }

        var consumed = false
        var convError: NSError?
        conv.convert(to: out, error: &convError) { _, outStatus in
            if consumed { outStatus.pointee = .endOfStream; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return source
        }
        if convError != nil || out.frameLength == 0 { return nil }
        return out
    }

    // `readDefaultInputDeviceName()` moved to `DefaultDeviceMonitor.swift` as
    // the free function `readDefaultDeviceName(forSelector:)`, shared between
    // this adapter and the UI-facing default-device monitor (audio-engine-008).
}
