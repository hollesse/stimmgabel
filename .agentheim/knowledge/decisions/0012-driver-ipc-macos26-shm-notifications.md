---
id: 0012
title: Driver IPC on macOS 26 — POSIX shared memory (audio frames) + Darwin notify (consumer-active signal)
scope: infrastructure
status: accepted
date: 2026-06-05
supersedes: []
superseded_by: []
related_tasks: []
related_research: []
---

# ADR 0012: Driver IPC on macOS 26 — POSIX shared memory (audio frames) + Darwin notify (consumer-active signal)

## Context

### What broke and why

`infrastructure-008` established the IPC channel between the app and the driver using
`AudioServerPlugIn_MachServices` + `xpc_connection_create_mach_service`. On macOS 26, Apple
introduced the **Remote Driver Service model**: Audio Server Plugins no longer load
in-process inside `coreaudiod`. Instead they run as separate sandboxed processes managed by
`com.apple.audio.Core-Audio-Driver-Service.helper` (confirmed by
`HALS_RemotePlugInRegistrar.mm` in production logs).

In this new execution model, `xpc_connection_create_mach_service(..., LISTENER)` inside the
driver returns a non-NULL connection object but **immediately fires
`XPC_ERROR_CONNECTION_INVALID`** in the event handler. The sandbox of the remote driver
service process does not permit registering global Mach bootstrap services. Fault-level
logging (ADR 0012 investigation, 2026-06-05) confirmed the exact sequence:

```
[FAULT] Initialize called
[FAULT] XPC: mach service listener created — resuming     ← non-NULL, no NULL guard
[FAULT] XPC: listener started and resumed                 ← resume() called
[standard] XPC listener error: Connection invalid         ← immediate rejection
```

The `AudioServerPlugIn_MachServices` Info.plist key is therefore inert under the new model.
The app side observes `xpc_error=[3: No such process]` on bootstrap look-up because no
service was ever successfully registered.

### Constraints any replacement must satisfy

1. **No Mach bootstrap registration.** The driver sandbox prohibits it on macOS 26.
2. **Zero-copy or near-zero-copy audio path.** `DoIOOperation` runs on a real-time thread;
   any IPC overhead on the hot path must be sub-microsecond. Serialisation (JSON, XPC dicts,
   `Data` copies) is too expensive.
3. **Low-latency consumer-active signal.** `StartIO`/`StopIO` fire from coreaudiod; the app
   must receive the signal within one render cycle (~10.67 ms at 512 frames / 48 kHz) to
   start or stop capturing upstream audio.
4. **Backward compatibility.** macOS 14.4+ (Sonoma) is still the minimum target. The
   replacement must work on both macOS 14/15 and macOS 26.
5. **Minimal structural change.** The `DriverIPCConnection` protocol and
   `FakeDriverIPCConnection` test double (ADR 0009) must survive unchanged so Tier-1 tests
   continue to pass.

## Alternatives considered

### A — Fix Mach service registration with `XPC_CONNECTION_MACH_SERVICE_PRIVILEGED`

Add the `XPC_CONNECTION_MACH_SERVICE_PRIVILEGED` flag on the driver's listener call.

**Rejected.** The privileged bootstrap namespace is root-owned. The remote driver service
process runs as `_coreaudiod` (not root). Privileged lookup requires root-level launchd
registration, which is not available to an Audio Server Plugin. This would not fix
`Connection invalid`.

### B — Reverse the XPC direction: app exposes a named service, driver connects

Register the Mach service from the app side (user process, no sandbox restrictions) and
have the driver connect as a client.

**Rejected.** The Remote Driver Service sandbox also restricts outbound Mach service
look-ups to un-declared services. There is no documented mechanism for a user-space app to
vend a service that a `_coreaudiod`-sandboxed driver can connect to. Background Music
(the canonical open-source reference) uses `AudioServerPlugIn_MachServices` and is
broken on macOS 26 for the same reason — confirming this is a systemic platform restriction,
not a configuration problem.

### C — Named FIFO (pipe)

A POSIX named pipe at a well-known path in `/tmp/`.

**Rejected for audio frames.** A FIFO is a byte stream with kernel buffering; every write
blocks until a reader is ready. On a real-time render thread (DoIOOperation), any blocking
is unacceptable. The pipe model also does not support random-access ring-buffer semantics.
Could theoretically work for the consumer-active signal but Darwin `notify_post` is simpler
and lower overhead.

### D — Memory-mapped file + kqueue

A regular file (e.g., in `~/Library/Application Support/Stimmgabel/`) memory-mapped by
both processes, with kqueue for the consumer-active signal.

**Rejected.** File-backed `mmap` is dirtied to the filesystem; on spinning disk this causes
occasional page faults on the real-time thread. kqueue requires a file descriptor per
watcher and is more complex to set up from C without blocking. POSIX SHM is in-kernel and
page-fault-free once faulted in; Darwin notifications are simpler than kqueue.

### E — CFNotificationCenter distributed notifications for both signal and audio

Use distributed `CFNotificationCenter` for everything, encoding audio frames as notification
user-info dictionaries.

**Rejected for audio frames.** Distributed notifications route through `notifyd`; there is
no guarantee of delivery within one render cycle, and encoding float arrays as plist data
introduces serialisation that violates constraint 2. Suitable only for the control-plane
signal.

### F — POSIX shared memory (`shm_open`/`mmap`) + Darwin `notify_post` ← **chosen**

Audio frames travel via a POSIX shared memory segment; consumer-active state changes travel
via Darwin notifications. See Decision section.

## Decision

Use **POSIX shared memory** for the audio ring buffer and **Darwin `notify_post` /
`notify_register_dispatch`** for the consumer-active signal.

### Audio path: POSIX shared memory ring buffer

The app process (`DriverOutputAdapter`) creates a named shared memory segment at startup:

```
shm_open("/stimmgabel-audio-v1", O_CREAT | O_RDWR | O_TRUNC, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
ftruncate(fd, sizeof(SHMAudioBuffer))
mmap(..., PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
```

`SHMAudioBuffer` (defined in `Sources/DriverIPC/SGSharedAudio.h`, inlined into the driver):

```c
#define SG_SHM_CAPACITY 4096u  // frames (≈ 85 ms @ 48 kHz) — matches ADR 0011

typedef struct {
    _Atomic(uint64_t) writePos;          // monotonic; app increments after each write
    _Atomic(uint64_t) readPos;           // monotonic; driver increments after each read
    float             samples[SG_SHM_CAPACITY * 2];  // interleaved stereo float32
} SHMAudioBuffer;
```

- The app writes frames to `samples[writePos % SG_SHM_CAPACITY * 2 ...]` and atomically
  increments `writePos`.
- The driver reads frames from `samples[readPos % SG_SHM_CAPACITY * 2 ...]` and
  atomically increments `readPos` (in `DoIOOperation`, exactly as the ring buffer today).
- Underrun (driver faster than app): driver emits silence, does not advance `readPos`.
- Overflow (app faster than driver): new frames overwrite unread frames. Acceptable
  degradation; same behaviour as the XPC ring buffer under backpressure.

**Why POSIX SHM over XPC for audio:**

`DoIOOperation` runs on a CoreAudio real-time I/O thread. Every microsecond of blocking or
copying matters. With POSIX `mmap`, the driver dereferences a pointer into shared memory —
zero copies, no kernel call on the read path. XPC required serialising `Data`, a round-trip
through `xpc_connection_send_message` (user→kernel→user), and a memcpy into the ring buffer.
POSIX SHM eliminates all three costs.

**Lifecycle:**
- App creates and `shm_unlink`s on clean shutdown.
- If app crashes: the SHM segment persists until the next `shm_open(..., O_CREAT | O_TRUNC)`
  by the next app launch — it is overwritten. No stale-data hazard.
- If driver opens SHM before app creates it: `shm_open` with `O_RDONLY` returns `-1
  / ENOENT`. The driver falls back to silence (existing underrun path). Once the app starts,
  the driver opens on the next `StartIO`. Acceptable; the user must launch the app before
  trying to record.

**Name versioning:** The segment name includes a version suffix (`-v1`) so a future
incompatible layout change can be deployed without a coordination window between app and
driver versions.

### Control plane: Darwin `notify_post` / `notify_register_dispatch`

```c
// Driver — StartIO:
notify_post("com.innoq.stimmgabel.consumer-active");

// Driver — StopIO:
notify_post("com.innoq.stimmgabel.consumer-inactive");
```

```swift
// App — SHMDriverIPCConnection:
var token: Int32 = NOTIFY_TOKEN_INVALID
notify_register_dispatch("com.innoq.stimmgabel.consumer-active", &token, queue) { _ in
    self.onConsumerActiveChanged?(true)
}
```

Darwin notifications (`libnotify` / `notify.h`) route through `notifyd` without Mach
bootstrap registration. They are available from both user processes and
`_coreaudiod`-sandboxed processes. Delivery latency is typically < 1 ms — well within one
render cycle.

This replaces the `setConsumerActive` XPC message from infrastructure-008. The notification
names are treated as stable API; any rename requires a `notify_post` of both old and new
names during a transition window.

### Changes to the `DriverIPCConnection` protocol

The `DriverIPCConnection` protocol in `Sources/AudioEngine/DriverOutputAdapter.swift`
remains unchanged. `XPCDriverIPCConnection` is **replaced** (not extended) by
`SHMDriverIPCConnection`, which:

- On `connect()`: opens the POSIX SHM segment (creates if absent) and maps it; registers
  Darwin notification observers.
- On `writeSamples(_:frameCount:)`: writes directly into the mapped `SHMAudioBuffer`.
- On dealloc: unmaps and (if owner) `shm_unlink`s.

`FakeDriverIPCConnection` and all existing Tier-1 tests are unchanged (constraint 5 ✓).

### Changes to `StimmgabelDriver.c`

- Remove: `SG_XPC_StartListener`, `SG_XPC_SendConsumerActive`, `SG_XPC_HandleMessage`,
  `SG_XPC_ClientEventHandler`, `xpcListener`, `xpcClientConn` state fields, XPC ring
  buffer write path.
- Add: `SG_SHM_Open` (called from `Initialize`; opens `/stimmgabel-audio-v1` with
  `O_RDWR | O_CREAT`; maps `SHMAudioBuffer`); `notify_post` calls in `StartIO`/`StopIO`;
  read from `SHMAudioBuffer` in `DoIOOperation`.
- The existing `SGRingBuffer` struct and read logic in `DoIOOperation` is **replaced** by
  direct reads from `SHMAudioBuffer.samples` (same lock-free atomic index arithmetic).
- `SHMAudioBuffer` layout is shared between driver and app via a header in
  `Sources/DriverIPC/SGSharedAudio.h` (existing package; driver inlines it as it does
  `SGRingBuffer.h` today per ADR 0011).

## Consequences

### Positive

- **Zero-copy audio on the real-time path.** `DoIOOperation` reads directly from mapped
  memory with no kernel call overhead. This is strictly better than the XPC approach.
- **No bootstrap registration.** Both POSIX SHM and Darwin `notify_post` work inside the
  Remote Driver Service sandbox on macOS 26 and on macOS 14/15.
- **Simpler driver.** Removes ~100 lines of XPC server code (listener lifecycle, connection
  tracking, message dispatch). The driver becomes a pure consumer of shared memory.
- **Existing Tier-1 tests unchanged.** The `DriverIPCConnection` protocol abstraction
  (ADR 0009) fully contains the change; `FakeDriverIPCConnection` needs no edits.

### Negative

- **No delivery guarantee on notifications.** Darwin notifications are best-effort. Under
  extreme system load, a `notify_post` could be lost. Consequence: app misses
  `consumer-active` and stays Idle while the driver is serving silence. Mitigation: the
  user can toggle the consumer off/on (stop and restart recording in Handy) to re-trigger
  `StartIO`/`StopIO`. A future improvement could add a heartbeat (driver posts
  `consumer-active` every 5 seconds while IO is running; app reconciles state on each
  heartbeat). Not implemented in v1.
- **SHM persists on app crash.** Stale SHM is overwritten on the next app launch
  (`O_TRUNC`), so no correctness hazard, but a crashed-and-not-restarted app leaves the
  segment until next launch or reboot. Acceptable for v1.
- **macOS 26 only diagnosis.** This ADR is written based on empirical evidence (fault-level
  logging during debugging, 2026-06-05). Apple has not published release notes documenting
  the Remote Driver Service sandbox change. The fix is grounded in observed behaviour, not
  in SDK documentation. If a future macOS release reverts the restriction, `XPCDriverIPCConnection`
  could be restored — but the SHM approach performs better regardless, so no revert is planned.

### Neutral

- POSIX SHM names (`/stimmgabel-audio-v1`) are global on the machine. A second instance of
  Stimmgabel would collide. Single-user, single-instance (ADR 0001) makes this a non-issue
  for v1.
- `notify_post` names are also global. Name-collision risk with other apps is negligible
  given the `com.innoq.stimmgabel` prefix.

## References

- ADR 0005 — Audio Server Plugin publishing mechanism; XPC IPC pattern (now superseded for
  the IPC channel by this ADR; the plugin install and signing remain as specified)
- ADR 0009 — Testing strategy; `DriverIPCConnection` protocol seam that contains this change
- ADR 0011 — Ring buffer design; `SHMAudioBuffer` reuses the same capacity and lock-free
  index arithmetic
- `infrastructure-008` — Original XPC implementation being replaced
- Apple `man shm_open(2)`, `man notify(3)` — platform API references
- Fault-level log evidence: `[Stimmgabel][FAULT] XPC: listener started and resumed` /
  `XPC listener error: Connection invalid` — 2026-06-05 22:16:59
