import Foundation
import Darwin
import notify
import DriverIPC
import os

// MARK: - SHM layout constants (mirrors SGSharedAudio.h, ADR 0012)

private let kSHMName: String       = "/stimmgabel-audio-v1"
private let kSHMCapacity: UInt64   = 4096        // frames
private let kNotifyActive: String  = "com.innoq.stimmgabel.consumer-active"
private let kNotifyInactive: String = "com.innoq.stimmgabel.consumer-inactive"

// SHMAudioBuffer layout (must match the C struct exactly):
//   offset  0 : UInt64  writePos  (8 bytes)
//   offset  8 : UInt64  readPos   (8 bytes)
//   offset 16 : Float * kSHMCapacity * 2  (4096 * 2 * 4 = 32768 bytes)
// Total: 32784 bytes.
private let kSHMSize: Int = 8 + 8 + Int(kSHMCapacity) * 2 * MemoryLayout<Float>.size

private let log = Logger(subsystem: "com.innoq.stimmgabel", category: "SHMDriverIPCConnection")

// MARK: - SHMDriverIPCConnection

/// Production IPC connection to the Stimmgabel virtual audio driver via POSIX
/// shared memory + Darwin notify (ADR 0012).
///
/// Replaces `XPCDriverIPCConnection` which is non-functional on macOS 26 due to
/// Remote Driver Service sandbox restrictions on Mach service registration.
///
/// Thread safety:
/// - `connect()` is safe to call from any thread.
/// - `writeSamples` is safe to call from any thread (serialised via `queue`).
/// - The pointer write to `writePos` is 64-bit aligned; on ARM64 aligned 64-bit
///   stores are atomic. The driver reads `writePos` with `memory_order_acquire`
///   so all sample writes preceding the store become visible.
public final class SHMDriverIPCConnection: DriverIPCConnection, @unchecked Sendable {

    public var onConsumerActiveChanged: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "com.innoq.stimmgabel.SHMDriverIPCConnection")
    private var shmPtr: UnsafeMutableRawPointer?
    private var shmFd: Int32 = -1
    private var activeToken: Int32 = NOTIFY_TOKEN_INVALID
    private var inactiveToken: Int32 = NOTIFY_TOKEN_INVALID

    public init() {}

    deinit {
        if activeToken != NOTIFY_TOKEN_INVALID {
            notify_cancel(activeToken)
        }
        if inactiveToken != NOTIFY_TOKEN_INVALID {
            notify_cancel(inactiveToken)
        }
        if let ptr = shmPtr {
            munmap(ptr, kSHMSize)
        }
        if shmFd >= 0 {
            close(shmFd)
        }
        // Do NOT unlink the SHM segment here. The driver helper process keeps
        // its mmap alive across app restarts (it only re-runs Initialize after a
        // full coreaudiod restart). If we unlink the name, the next app instance
        // creates a brand-new segment that the driver can never see, causing
        // permanent silence until the entire driver helper is restarted.
        // The segment is intentionally left in the namespace so the next app
        // instance can open the same physical pages the driver is already mapped to.
    }

    // MARK: - Connect

    /// Open (or create) the shared memory segment and register Darwin notify handlers.
    public func connect() {
        queue.async { [weak self] in
            self?.openSHM()
            self?.registerNotifications()
        }
    }

    // MARK: - DriverIPCConnection

    public func writeSamples(_ data: Data, frameCount: UInt32) {
        queue.async { [weak self] in
            self?.writeToSHM(data, frameCount: frameCount)
        }
    }

    // MARK: - Private: SHM

    private func openSHM() {
        var fd = sg_shm_open(kSHMName, O_CREAT | O_RDWR, 0o666)
        if fd < 0 {
            log.error("shm_open(\(kSHMName, privacy: .public)) failed: errno=\(errno, privacy: .public)")
            return
        }

        if ftruncate(fd, off_t(kSHMSize)) < 0 {
            // ftruncate fails with EINVAL when the segment already exists and is
            // currently mmap'd by the driver — the kernel rejects resizing a live
            // mapping. Check whether the existing segment is already the right size.
            var info = stat()
            let alreadySized = (fstat(fd, &info) == 0) && (info.st_size == off_t(kSHMSize))
            if alreadySized {
                // The driver is still mapped to this exact segment. Reuse it so
                // the driver and the new app session share the same physical pages.
                log.info("SHM already the right size; reusing existing segment (driver keeps its mapping)")
            } else {
                // Wrong size — truly stale. Unlink and recreate from scratch.
                log.info("ftruncate failed (errno=\(errno, privacy: .public)) and size mismatch; recreating SHM")
                close(fd)
                sg_shm_unlink(kSHMName)
                fd = sg_shm_open(kSHMName, O_CREAT | O_RDWR, 0o666)
                if fd < 0 {
                    log.error("shm_open after unlink failed: errno=\(errno, privacy: .public)")
                    return
                }
                if ftruncate(fd, off_t(kSHMSize)) < 0 {
                    log.error("ftruncate after recreate failed: errno=\(errno, privacy: .public)")
                    close(fd)
                    return
                }
            }
        }

        let mapped = mmap(nil, kSHMSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        if mapped == MAP_FAILED || mapped == nil {
            log.error("mmap(\(kSHMSize, privacy: .public)) failed: errno=\(errno, privacy: .public)")
            close(fd)
            return
        }

        // Zero-initialise so writePos/readPos reset to 0 for this session. The
        // driver will deliver silence until the first audio frame is written, which
        // is correct. When reusing an existing segment both the app's new mmap and
        // the driver's existing mmap point to the same physical pages, so the
        // driver immediately sees the reset and the subsequent audio writes.
        mapped!.initializeMemory(as: UInt8.self, repeating: 0, count: kSHMSize)

        shmFd  = fd
        shmPtr = mapped

        log.info("SHM open: fd=\(fd, privacy: .public) size=\(kSHMSize, privacy: .public) ptr=\(String(describing: mapped), privacy: .public)")
    }

    private func writeToSHM(_ data: Data, frameCount: UInt32) {
        guard let ptr = shmPtr else { return }

        // Read current writePos (relaxed — we are the sole producer).
        let writePosPtr = ptr.advanced(by: 0).assumingMemoryBound(to: UInt64.self)
        let writePos = writePosPtr.pointee          // relaxed read; we own this field

        let samplesPtr = ptr.advanced(by: 16).assumingMemoryBound(to: Float.self)
        let framesToWrite = min(UInt64(frameCount), kSHMCapacity)

        data.withUnsafeBytes { raw in
            guard let src = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            for i in 0 ..< framesToWrite {
                let slot = (writePos + i) % kSHMCapacity
                samplesPtr[Int(slot) * 2]     = src[Int(i) * 2]
                samplesPtr[Int(slot) * 2 + 1] = src[Int(i) * 2 + 1]
            }
        }

        // Release store: all sample writes above are visible to the driver before
        // writePos advances. On ARM64, a `stlr` is emitted for this store.
        // Swift does not expose C11 atomics directly, but we can use OSAtomicAdd64Barrier
        // (or simply write the pointer with an `os_unfair_lock`-free barrier).
        // The simplest correct approach: use atomic_thread_fence via OSMemoryBarrier().
        OSMemoryBarrier()
        writePosPtr.pointee = writePos + framesToWrite
    }

    // MARK: - Private: Darwin notify

    private func registerNotifications() {
        let notifyQueue = DispatchQueue(label: "com.innoq.stimmgabel.SHMDriverIPCConnection.notify")

        var tok1: Int32 = NOTIFY_TOKEN_INVALID
        let result1 = notify_register_dispatch(kNotifyActive, &tok1, notifyQueue) { [weak self] _ in
            log.info("Darwin notify: consumer-active")
            self?.onConsumerActiveChanged?(true)
        }
        if result1 == NOTIFY_STATUS_OK {
            activeToken = tok1
        } else {
            log.error("notify_register_dispatch(\(kNotifyActive, privacy: .public)) failed: \(result1, privacy: .public)")
        }

        var tok2: Int32 = NOTIFY_TOKEN_INVALID
        let result2 = notify_register_dispatch(kNotifyInactive, &tok2, notifyQueue) { [weak self] _ in
            log.info("Darwin notify: consumer-inactive")
            self?.onConsumerActiveChanged?(false)
        }
        if result2 == NOTIFY_STATUS_OK {
            inactiveToken = tok2
        } else {
            log.error("notify_register_dispatch(\(kNotifyInactive, privacy: .public)) failed: \(result2, privacy: .public)")
        }

        log.info("Darwin notify registered: activeToken=\(tok1, privacy: .public) inactiveToken=\(tok2, privacy: .public)")
    }
}
