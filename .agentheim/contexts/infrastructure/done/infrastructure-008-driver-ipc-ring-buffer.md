---
id: infrastructure-008
title: Driver IPC — Mach service, ring buffer, XPC server in Stimmgabel.driver
status: done
type: feature
context: infrastructure
created: 2026-06-05
completed: 2026-06-05
commit: bb3e71a
depends_on: []
blocks: [audio-engine-006]
tags: [driver, coreaudio, audio-server-plugin, ipc, xpc, ring-buffer]
related_adrs: [0005, 0011]
related_research: [audio-server-plugin-macos26-2026-06-05]
prior_art: [infrastructure-006, infrastructure-007]
---

## Why

The driver currently outputs silence. To emit the app's mixed audio, it needs a path to receive
sample data from the app process. ADR 0005 decided this path is a Mach service / XPC bridge backed
by a ring buffer: the app pushes mix frames into the driver's ring buffer when a consumer is
reading; `DoIOOperation` drains it.

## What

Extend `Stimmgabel.driver` and its companion XPC setup so the driver exposes a named Mach service
that the app (audio-engine) can connect to and write mix frames into.

Concretely:

1. **Info.plist** — add `AudioServerPlugIn_MachServices` key with the service name
   `com.innoq.stimmgabel.driver` (matches the convention from Apple QA1811).

2. **Ring buffer in the driver** — allocate a fixed-size lock-free ring buffer (e.g. 4096 frames ×
   float32 × 2 channels) in global driver state. `DoIOOperation` reads from this buffer when a
   consumer is active; if underrun occurs, emit silence for that cycle.

3. **XPC server** — inside the driver helper process, implement a minimal XPC interface:
   - `writeSamples(buffer: Data, frameCount: UInt32)` — app pushes a buffer of interleaved or
     non-interleaved float32 stereo frames; driver copies them into the ring buffer.
   - `setConsumerActive(_ active: Bool)` — driver notifies the app that a consumer has started /
     stopped reading (derived from `StartIO` / `StopIO` callbacks). This drives lazy activation.
   - Connection lifecycle: accept one connection from the app; if the app disconnects, drain the
     ring buffer gracefully and emit silence until reconnect.

4. **`DoIOOperation` change** — replace the `memset(ioMainBuffer, 0, …)` silence with a ring-buffer
   drain of `inIOBufferFrameSize` frames. If the buffer holds fewer frames than requested, zero-fill
   the remainder.

5. **Lazy-activation signal** — on `StartIO`, send `setConsumerActive(true)` to the connected app;
   on `StopIO`, send `setConsumerActive(false)`. The app uses these to open / tear down its upstream
   captures (Process Tap + mic IOProc). If no app is connected, the driver simply emits silence.

## Acceptance criteria

- [ ] `Stimmgabel.driver/Contents/Info.plist` contains an `AudioServerPlugIn_MachServices` array
      with one entry: `"com.innoq.stimmgabel.driver"`.
- [ ] After `script/install-driver.sh`, `coreaudiod` loads the driver and the XPC service name is
      visible (e.g. via `launchctl print-disabled user/…` or Console logs showing the service
      registration).
- [ ] A standalone test (unit or integration) writes N frames into the driver via the XPC client
      interface and verifies `DoIOOperation` drains those exact frames (not silence) in the next
      render cycle.
- [ ] When no app is connected, `DoIOOperation` emits silence — no crash, no hang.
- [ ] `StartIO` sends `setConsumerActive(true)` to the connected client (verified by test or log).
- [ ] `StopIO` sends `setConsumerActive(false)` (verified by test or log).
- [ ] Existing Tier-1 unit tests in `AudioEngineTests` continue to pass (no regression).

## Notes

- The driver process is `com.apple.audio.Core-Audio-Driver-Service.helper`, sandboxed. The Mach
  service name must be declared in Info.plist **before** the driver is reinstalled — coreaudiod
  reads the plist at load time.
- The XPC service in the driver is a *client-facing* server: the driver listens, the app connects.
  This is unusual but is exactly how Background Music's BGMDriver ↔ BGMApp bridge works.
- The ring buffer size should absorb at least ~5 HAL render cycles of jitter (HAL typically runs
  at 512 frames / 48 kHz ≈ 10 ms; 5× ≈ 50 ms of buffer). Start at 4096 frames.
- Use `os_log` (already in the driver) for XPC connection events — critical for future debugging.
- `GetZeroTimeStamp` currently returns `startHostTime` as `outHostTime` (never advances). This will
  cause timing drift once real audio flows. Fix in a follow-up if audible, but note the issue.

## Outcome

- `App/StimmgabelDriver/Info.plist` — added `AudioServerPlugIn_MachServices` array with entry
  `com.innoq.stimmgabel.driver`.
- `App/StimmgabelDriver/StimmgabelDriver.c` — full IPC implementation:
  - Lock-free ring buffer (4096 frames × interleaved float32 stereo) inlined from
    `Sources/DriverIPC/SGRingBuffer.c`.
  - XPC server registered on `com.innoq.stimmgabel.driver` via
    `xpc_connection_create_mach_service(..., LISTENER)`. Accepts one client at a time.
  - `writeSamples(data:frameCount:)` message handler copies interleaved frames into ring buffer.
  - `StartIO` sends `setConsumerActive(true)`, `StopIO` sends `setConsumerActive(false)`.
  - `DoIOOperation` drains ring buffer (left + right deinterleaved); underrun → silence.
  - When no client connected, driver emits silence without crash.
  - `QueryInterface` uses `memcmp(&inUUID, bytes, sizeof(CFUUIDBytes))` (correct for macOS 26
    where `REFIID = CFUUIDBytes` by value).
- `Sources/DriverIPC/include/SGRingBuffer.h` + `Sources/DriverIPC/SGRingBuffer.c` — canonical
  ring buffer implementation for the SPM test target.
- `Tests/DriverIPCTests/DriverIPCTests.swift` — 7 new Tier-1 tests; all pass.
- `Package.swift` — added `DriverIPC` C target and `DriverIPCTests` test target.
- `.agentheim/knowledge/decisions/0011-driver-ipc-ring-buffer-design.md` — ADR for design
  decisions (interleaved storage, inlining strategy, REFIID type, XPC pattern).
- `contexts/infrastructure/README.md` — updated with IPC implementation notes.
