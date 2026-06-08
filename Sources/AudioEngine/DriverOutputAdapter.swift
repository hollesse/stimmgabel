import Foundation
import os

// MARK: - IPC abstraction

public protocol DriverIPCConnection: AnyObject, Sendable {
    /// Push `frameCount` interleaved float32 stereo frames to the driver's ring buffer.
    func writeSamples(_ data: Data, frameCount: UInt32)
    var onConsumerActiveChanged: ((Bool) -> Void)? { get set }
}

// MARK: - DriverOutputAdapter

private let log = Logger(subsystem: "com.innoq.stimmgabel", category: "DriverOutputAdapter")

/// Bridges the system-audio IOProc to the driver's SHM ring buffer.
///
/// On consumer-active: starts the system-audio adapter and wires its output
/// directly to `ipc.writeSamples` via `AudioPipeline.outputSink`.
/// On consumer-inactive: stops the adapter and clears the sink.
///
/// No render timer — writes are driven by the IOProc's hardware clock, which
/// is the same coreaudiod clock the driver uses.  This eliminates the
/// software/hardware clock drift that caused robotic stuttering.
public final class DriverOutputAdapter: @unchecked Sendable {

    // Kept for API compatibility; not used in the direct-write model.
    public static let renderFrameCount: Int = 512
    public static let sampleRate: Double = 48_000

    private let pipeline: AudioPipeline
    private let ipc: any DriverIPCConnection
    private let queue = DispatchQueue(label: "com.innoq.stimmgabel.DriverOutputAdapter")
    private var consumerActive: Bool = false

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

    private func handleConsumerActive(_ active: Bool) {
        queue.async { [weak self] in
            guard let self, active != consumerActive else { return }
            consumerActive = active
            log.info("Consumer active: \(active, privacy: .public)")
            if active {
                // Wire IOProc output directly to SHM — no render timer needed.
                pipeline.outputSink = { [weak ipc] data, frameCount in
                    ipc?.writeSamples(data, frameCount: frameCount)
                }
                pipeline.consumerAttached()
            } else {
                pipeline.consumerDetached()
                pipeline.outputSink = nil
            }
        }
    }

    func syncBarrier() { queue.sync { } }
}
