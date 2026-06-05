import Foundation
import os

// MARK: - IPC abstraction (seam for Tier-1 testing, ADR 0009)

/// The minimal interface the output adapter needs from the driver IPC channel.
///
/// The production implementation uses POSIX SHM + Darwin notify (ADR 0012);
/// tests substitute a fake.
public protocol DriverIPCConnection: AnyObject, Sendable {
    /// Push `frameCount` interleaved float32 stereo frames to the driver's ring buffer.
    /// Fire-and-forget — the call returns immediately.
    func writeSamples(_ data: Data, frameCount: UInt32)

    /// Called by the adapter to register for consumer-active change notifications.
    /// The handler is called on an arbitrary queue.
    var onConsumerActiveChanged: ((Bool) -> Void)? { get set }
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
    ///   - ipc: The IPC connection to the driver.  Defaults to the production SHM connection (ADR 0012).
    public init(
        pipeline: AudioPipeline,
        ipc: any DriverIPCConnection = SHMDriverIPCConnection()
    ) {
        self.pipeline = pipeline
        self.ipc = ipc

        ipc.onConsumerActiveChanged = { [weak self] active in
            self?.handleConsumerActive(active)
        }

        if let shmConn = ipc as? SHMDriverIPCConnection {
            shmConn.connect()
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
