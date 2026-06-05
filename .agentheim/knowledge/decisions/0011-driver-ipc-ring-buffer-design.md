---
id: 0011
title: Driver IPC ring buffer — lock-free SP/SR interleaved float32, inlined in driver
scope: infrastructure
status: accepted
date: 2026-06-05
related_tasks: [infrastructure-008]
---

# ADR 0011: Driver IPC ring buffer — lock-free SP/SR interleaved float32, inlined in driver

## Context

ADR 0005 decided on a Mach service / XPC bridge for the app → driver audio path.
The driver (Audio Server Plugin) runs in a sandboxed helper process; the app
connects as an XPC client and pushes mix frames. `DoIOOperation` must drain those
frames on the CoreAudio I/O thread.

## Decision

### Ring buffer format and placement

- **Format:** interleaved float32, 4096 frames × 2 channels (≈ 85 ms @ 48 kHz).
  App writes interleaved `[L0, R0, L1, R1, …]`; driver deinterleaves on drain.
  4096 frames absorbs ≥ 5 HAL cycles of 512-frame jitter as required by the task.

- **Implementation:** single-producer / single-reader lock-free ring buffer using
  C11 `_Atomic(uint32_t)` head indices. Heads use natural `uint32_t` overflow;
  `(head & (capacity - 1))` gives the sample-array slot. This avoids explicit
  modulo wrapping and is correct because the capacity is a power of two.

- **Source location:** The ring buffer is implemented twice:
  1. `Sources/DriverIPC/SGRingBuffer.{h,c}` — the canonical implementation, tested
     via the `DriverIPCTests` SPM target.
  2. Inlined verbatim into `App/StimmgabelDriver/StimmgabelDriver.c` — keeps the
     driver self-contained without requiring Xcode project changes to add a new
     source file.

  The two implementations must be kept in sync. The SPM target tests the canonical
  version; the driver version is a copy.

### Why interleaved storage

The app's mix engine will produce interleaved stereo naturally (one write per
render cycle). Deinterleaving at drain time (in the driver) keeps the write path
simple and avoids any alignment concerns with the XPC data copy.

### Why inline in the driver

Adding `SGRingBuffer.c` to the Xcode project's `StimmgabelDriver` target would
require editing `project.pbxproj` manually — fragile and hard to review. Inlining
via static functions in a single `.c` file avoids this. The ring buffer is small
(< 80 lines) and the duplication is acceptable given the test coverage on the
canonical implementation.

### DoIOOperation channel-multiplexing strategy

The stream format is non-interleaved 2-channel (kAudioFormatFlagIsNonInterleaved).
CoreAudio calls `DoIOOperation` once per channel per I/O cycle. On the first call,
we drain left+right into the caller's buffer (left) and a static scratch buffer
(right). On the second call, we copy from scratch. A `gScratchReady` flag tracks
which call we're on. This relies on CoreAudio serialising the two channel calls
sequentially within the same I/O cycle (which it always does — the I/O thread is
single-threaded per cycle).

### XPC server pattern

The driver acts as the **server** (unusual: drivers typically are clients).
`xpc_connection_create_mach_service(..., XPC_CONNECTION_MACH_SERVICE_LISTENER)`
creates the listener. The Mach service name `com.innoq.stimmgabel.driver` is
declared in `Info.plist` under `AudioServerPlugIn_MachServices` (Apple QA1811).

The driver accepts one client connection at a time. On `StartIO` / `StopIO`,
the driver sends `setConsumerActive(true/false)` to the connected client via
`xpc_connection_send_message`. The app uses this to start/stop its upstream
captures (lazy activation — only capture when someone is reading).

### REFIID type in macOS 26

In the macOS 26 SDK, `REFIID = CFUUIDBytes` (a 16-byte struct by value, from
`CFPlugInCOM.h`). `QueryInterface`'s `inUUID` parameter is therefore already the
raw UUID bytes. The correct comparison is:
```c
memcmp(&inUUID, kInterfaceBytes, sizeof(CFUUIDBytes)) == 0
```
Do NOT call `CFUUIDGetUUIDBytes(inUUID)` — that function expects a `CFUUIDRef`
(opaque pointer), not a `CFUUIDBytes` value.

## Consequences

- The ring buffer must be kept in sync between `Sources/DriverIPC/` and
  `StimmgabelDriver.c`. Any change to the algorithm must update both.
- The `gScratchRight` static buffer assumes the HAL never requests more than
  `sizeof(gScratchRight) / sizeof(float)` frames per cycle. Currently provisioned
  for 2048 floats (512 × 4), well above the typical 512-frame HAL cycle.
- `GetZeroTimeStamp` still returns a fixed `startHostTime` and never advances
  (pre-existing issue from the walking skeleton). This causes timing drift once
  real audio flows. Tracked as a follow-up.
