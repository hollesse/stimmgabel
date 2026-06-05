---
id: audio-engine-006
title: Output adapter — XPC client that writes mix frames into the driver ring buffer and handles lazy activation
status: done
type: feature
context: audio-engine
created: 2026-06-05
completed: 2026-06-05
commit:
depends_on: [audio-engine-005, infrastructure-008]
blocks: [menubar-ui-002, menubar-ui-003]
tags: [output, xpc, ipc, ring-buffer, lazy-activation, driver]
related_adrs: [0005, 0010, 0009]
related_research: []
prior_art: [audio-engine-002]
---

## Why

The mix produced by the engine needs to reach the driver's ring buffer each render cycle so the
virtual mic delivers real audio to consumer apps. The bridge is the XPC channel decided in ADR 0005.
Lazy activation (only capturing when a consumer reads) also flows through this adapter: the driver
sends `setConsumerActive` signals, and the output adapter translates them into `start()` / `stop()`
calls on the upstream adapters.

## What

Implement a `DriverOutputAdapter` in the `AudioEngine` Swift module that:

1. **Connects to the driver's Mach service** — on app launch, establishes an XPC connection to
   `com.innoq.stimmgabel.driver` (the service name declared in the driver's Info.plist by
   infrastructure-008). Reconnects automatically if the connection drops (coreaudiod restarts the
   driver process).

2. **Pushes mix frames** — whenever the mix step (audio-engine-005) produces an output buffer,
   the adapter serialises it and sends it via `writeSamples(buffer:frameCount:)` to the driver.
   The send is asynchronous (fire-and-forget); backpressure comes from the driver's ring buffer
   being full, which the adapter detects by tracking bytes-in-flight.

3. **Handles lazy-activation signals** — receives `setConsumerActive(true/false)` from the driver.
   On `true`: calls `micAdapter.start()` and `systemAudioAdapter.start()` (or delegates to
   `AudioPipeline`). On `false`: calls `stop()` on both. This implements the core invariant
   *"upstream captures run iff a consumer is reading"*.

4. **Owns the render-cycle clock** — in the absence of a hardware clock (the driver runs at its
   own HAL cadence), the output adapter drives the mix cadence: it requests a new buffer from
   the mixer every N frames based on the driver's declared `kZeroTimeStampPeriod` (512 frames at
   48 kHz ≈ 10 ms). A `DispatchSourceTimer` or similar drives this loop while a consumer is active.

5. **Graceful degradation** — if the XPC connection is not established (driver not installed, or
   just reinstalled and not yet loaded), the adapter logs and enters a "no-op" state; the app
   continues running without crashing.

## Acceptance criteria

- [ ] After connecting, `DriverOutputAdapter` sends mix frames continuously while a consumer is
      active; the virtual mic emits non-silent audio (Tier-2 / manual integration test: record
      from Stimmgabel in QuickTime or Handy).
- [ ] With no consumer reading, no mix frames are produced and no upstream captures are running
      (verify via Console log — no `StartIO` without a consumer).
- [ ] Plugging in a consumer (e.g. opening Quicktime, selecting Stimmgabel as input) causes
      `setConsumerActive(true)` → both adapters start; unplugging causes `stop()` (Tier-2 test
      or manual observation).
- [ ] If the XPC connection drops (driver restarted), the adapter reconnects and resumes; no crash.
- [ ] Tier-1 unit test: `DriverOutputAdapter` with a fake XPC stub verifies that `start()`/`stop()`
      are called at the right times in response to simulated consumer-active signals.
- [ ] Existing Tier-1 tests continue to pass.

## Notes

- The render-cycle timer period should match the driver's `kZeroTimeStampPeriod` / sample rate:
  512 / 48000 ≈ 10.67 ms. A small jitter (±1 ms) is fine; the driver's ring buffer absorbs it.
- `GetZeroTimeStamp` in the driver currently always returns `startHostTime` as `outHostTime` —
  this causes clock drift. Note this as a known issue; fix it if audible jitter appears in practice
  (a separate bug task, not this task's scope).
- Use `os_log` for all consumer-active transitions and XPC connection events.
- The XPC message encoding can be simple `Data` (raw float32 bytes) for v1 — no Codable, no JSON.
- Do not implement per-side volume gain here — that belongs in the mixer (audio-engine-005 notes).

## Outcome

Implemented `DriverOutputAdapter` in `Sources/AudioEngine/DriverOutputAdapter.swift`:

- `DriverIPCConnection` protocol — seam for Tier-1 testing; `writeSamples(_:frameCount:)` and `onConsumerActiveChanged` handler.
- `XPCDriverIPCConnection` — production implementation; connects to `com.innoq.stimmgabel.driver` via `xpc_connection_create_mach_service`, handles `setConsumerActive` inbound messages, fires `writeSamples` as XPC dictionary messages, auto-reconnects on `XPC_ERROR_CONNECTION_INTERRUPTED` with a 1 s delay.
- `DriverOutputAdapter` — owns a `DispatchSourceTimer` (512 frames / 48 kHz ≈ 10.67 ms) that fires `pipeline.mix(frameCount:)` → raw float32 `Data` → `ipc.writeSamples`; starts/stops the timer on consumer-active transitions; maps `setConsumerActive(true)` → `pipeline.consumerAttached()` and `false` → `pipeline.consumerDetached()`.
- `syncBarrier()` test helper on `DriverOutputAdapter` for deterministic queue drain in tests.

7 new Tier-1 tests in `Tests/AudioEngineTests/DriverOutputAdapterTests.swift`, all passing.
All 27 pre-existing `AudioPipelineTests` continue to pass.
Known issue: `GetZeroTimeStamp` in the driver never advances `outHostTime` — clock drift if jitter is audible; tracked as a separate bug task.
