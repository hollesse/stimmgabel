import Foundation
import os

// MARK: - IPC abstraction (seam for Tier-1 testing, ADR 0009)

/// The minimal interface the output adapter needs from the driver IPC channel.
///
/// The production implementation wraps an XPC connection; tests substitute a fake.
public protocol DriverIPCConnection: AnyObject, Sendable {
    /// Push `frameCount` interleaved float32 stereo frames to the driver's ring buffer.
    /// Fire-and-forget — the call returns immediately.
    func writeSamples(_ data: Data, frameCount: UInt32)

    /// Called by the adapter to register for consumer-active change notifications.
    /// The handler is called on an arbitrary queue.
    var onConsumerActiveChanged: ((Bool) -> Void)? { get set }
}

// MARK: - XPC IPC implementation

/// Production XPC connection to `com.innoq.stimmgabel.driver`.
///
/// The driver is the XPC server (listener); the app is the client that connects once
/// and reconnects automatically if the driver process restarts (see infrastructure-008).
public final class XPCDriverIPCConnection: DriverIPCConnection, @unchecked Sendable {

    private static let serviceName = "com.innoq.stimmgabel.driver"
    private static let log = Logger(subsystem: "com.innoq.stimmgabel", category: "XPCDriverIPCConnection")

    private let queue = DispatchQueue(label: "com.innoq.stimmgabel.XPCDriverIPCConnection")
    private var connection: xpc_connection_t?

    public var onConsumerActiveChanged: ((Bool) -> Void)?

    public init() {}

    /// Establish the XPC connection.  Safe to call multiple times (reconnect).
    public func connect() {
        queue.async { [weak self] in
            self?.establishConnection()
        }
    }

    // MARK: - DriverIPCConnection

    public func writeSamples(_ data: Data, frameCount: UInt32) {
        queue.async { [weak self] in
            guard let self, let conn = self.connection else { return }
            let msg = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(msg, "type", "writeSamples")
            data.withUnsafeBytes { ptr in
                xpc_dictionary_set_data(msg, "buffer", ptr.baseAddress!, ptr.count)
            }
            xpc_dictionary_set_uint64(msg, "frameCount", UInt64(frameCount))
            xpc_connection_send_message(conn, msg)
        }
    }

    // MARK: - Private

    private func establishConnection() {
        if let existing = connection {
            xpc_connection_cancel(existing)
            connection = nil
        }

        let conn = xpc_connection_create_mach_service(
            Self.serviceName,
            queue,
            0  // client (not listener)
        )

        xpc_connection_set_event_handler(conn) { [weak self] event in
            self?.handleXPCEvent(event)
        }

        xpc_connection_resume(conn)
        connection = conn
        Self.log.info("XPC connection established to \(Self.serviceName, privacy: .public)")
    }

    private func handleXPCEvent(_ event: xpc_object_t) {
        let type = xpc_get_type(event)

        if type == XPC_TYPE_ERROR {
            if xpc_equal(event, XPC_ERROR_CONNECTION_INTERRUPTED) {
                Self.log.warning("XPC connection interrupted — scheduling reconnect")
                // Driver process restarted; reconnect after a short delay.
                queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.establishConnection()
                }
            } else if xpc_equal(event, XPC_ERROR_CONNECTION_INVALID) {
                Self.log.error("XPC connection invalid — driver not installed or not loaded")
                connection = nil
            }
            return
        }

        guard type == XPC_TYPE_DICTIONARY else { return }

        let msgType = xpc_dictionary_get_string(event, "type").flatMap { String(cString: $0) }
        if msgType == "setConsumerActive" {
            let active = xpc_dictionary_get_bool(event, "active")
            Self.log.info("Received setConsumerActive(\(active, privacy: .public))")
            onConsumerActiveChanged?(active)
        }
    }
}

// MARK: - DriverOutputAdapter

private let log = Logger(subsystem: "com.innoq.stimmgabel", category: "DriverOutputAdapter")

/// Drives the render cycle and bridges the `AudioPipeline` mix output to the driver's ring buffer.
///
/// Responsibilities (ADR 0005, ADR 0010):
/// - Owns the render-cycle timer (512 frames at 48 kHz ≈ 10.67 ms per tick).
/// - On each tick while active: calls `pipeline.mix(frameCount:)` and pushes the result to the
///   driver via `DriverIPCConnection.writeSamples`.
/// - Receives `setConsumerActive(true/false)` from the driver and translates them into
///   `pipeline.consumerAttached()` / `pipeline.consumerDetached()`.
///
/// Thread safety: the render timer and IPC callbacks both route through `queue`; `AudioPipeline`
/// uses its own internal serial queue (ADR 0010), so calls from here are safe.
public final class DriverOutputAdapter: @unchecked Sendable {

    // MARK: - Constants

    /// Frames per render cycle (matches driver kZeroTimeStampPeriod, ADR 0005).
    public static let renderFrameCount: Int = 512
    /// Sample rate of the mix output (48 kHz, ADR 0006).
    public static let sampleRate: Double = 48_000
    /// Timer period ≈ 512/48000 ≈ 10.67 ms.
    private static var timerInterval: DispatchTimeInterval {
        .nanoseconds(Int(Double(renderFrameCount) / sampleRate * 1_000_000_000))
    }

    // MARK: - Dependencies

    private let pipeline: AudioPipeline
    private let ipc: any DriverIPCConnection

    // MARK: - State

    private let queue = DispatchQueue(label: "com.innoq.stimmgabel.DriverOutputAdapter")
    private var renderTimer: DispatchSourceTimer?
    private var consumerActive: Bool = false

    // MARK: - Init

    /// Create an output adapter.
    ///
    /// - Parameters:
    ///   - pipeline: The `AudioPipeline` to call `consumerAttached()` / `consumerDetached()` / `mix(frameCount:)` on.
    ///   - ipc: The IPC connection to the driver.  Defaults to the production XPC connection.
    public init(
        pipeline: AudioPipeline,
        ipc: any DriverIPCConnection = XPCDriverIPCConnection()
    ) {
        self.pipeline = pipeline
        self.ipc = ipc

        ipc.onConsumerActiveChanged = { [weak self] active in
            self?.handleConsumerActive(active)
        }

        if let xpcConn = ipc as? XPCDriverIPCConnection {
            xpcConn.connect()
        }
    }

    // MARK: - Consumer-active signal handling

    private func handleConsumerActive(_ active: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            guard active != consumerActive else { return }
            consumerActive = active
            log.info("Consumer active: \(active, privacy: .public)")

            if active {
                pipeline.consumerAttached()
                startRenderTimer()
            } else {
                stopRenderTimer()
                pipeline.consumerDetached()
            }
        }
    }

    // MARK: - Render timer

    private func startRenderTimer() {
        guard renderTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.timerInterval,
            repeating: Self.timerInterval,
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [weak self] in
            self?.renderTick()
        }
        timer.resume()
        renderTimer = timer
        log.debug("Render timer started")
    }

    private func stopRenderTimer() {
        renderTimer?.cancel()
        renderTimer = nil
        log.debug("Render timer stopped")
    }

    private func renderTick() {
        let frames = pipeline.mix(frameCount: Self.renderFrameCount)
        guard !frames.isEmpty else { return }
        let data = frames.withUnsafeBufferPointer { ptr in
            Data(buffer: ptr)
        }
        ipc.writeSamples(data, frameCount: UInt32(Self.renderFrameCount))
    }

    // MARK: - Testing support

    /// Block until all work enqueued on the adapter's serial queue has completed.
    ///
    /// Used by unit tests to avoid time-based waits (ADR 0009).
    /// Do NOT call from production code.
    func syncBarrier() {
        queue.sync { }
    }
}
