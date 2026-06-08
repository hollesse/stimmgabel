---
id: audio-engine-003
title: System-audio capture — Process Tap + aggregate device, rebind on default-output change
status: done
type: feature
context: audio-engine
created: 2026-06-05
completed: 2026-06-05
commit: 1394b39
depends_on: []
blocks: [audio-engine-005]
tags: [capture, process-tap, coreaudio, system-audio, aggregate-device, default-tracking]
related_adrs: [0004, 0009]
related_research: [macos-audio-platform-2026-06-05]
prior_art: [audio-engine-001]
---

## Why

Stimmgabel's system-audio side must capture all audio playing on the Mac — Zoom, browser, music,
notifications — and feed it into the mix. ADR 0004 decided the mechanism: `AudioHardwareCreateProcessTap`
with an empty process list (captures the current default output aggregate), wrapped in an aggregate
device so the tap has a stable `AudioDeviceID` the mic-side IOProc model can reuse.

## What

Implement a `SystemAudioAdapter` (or equivalent type) in the `AudioEngine` Swift module that:

1. **Creates a Process Tap** via `AudioHardwareCreateProcessTap` with a `CATapDescription` whose
   process list is empty. This captures all audio routed through the current default output.

2. **Wraps the tap in an aggregate device** (per ADR 0004) so it presents as a standard
   `AudioDeviceID` the rest of the pipeline can treat identically to the mic IOProc.

3. **Starts / stops on demand** — exposes `start()` and `stop()` methods. `start()` creates the
   tap + aggregate and registers an IOProc; `stop()` disposes them. Called by the lazy-activation
   logic in `AudioPipeline` when a consumer attaches / detaches.

4. **Rebinds on default-output change** — installs a property listener on
   `kAudioHardwarePropertyDefaultOutputDevice`. When it fires: stop the current tap, dispose the
   aggregate, recreate both on the new default output, resume — without interrupting the mix
   downstream.

5. **Delivers samples** via a callback (or `AsyncStream`) to the `AudioPipeline` mix step in the
   form of a `AVAudioPCMBuffer` or raw float32 pointer at the mix's target format (48 kHz /
   float32 / stereo). If the tap delivers a different format, convert via `AudioConverter`.

6. **Handles the App Sandbox question** — `AudioHardwareCreateProcessTap` is unconfirmed inside
   the App Sandbox (infrastructure-006 Q2, still open). v1 runs unsandboxed. If the API is
   unavailable in sandbox, fail with a clear log message; do not crash.

## Acceptance criteria

- [ ] `SystemAudioAdapter.start()` succeeds on a real Mac (macOS 14.4+) and the adapter delivers
      non-silent buffers when any audio is playing (manual integration test or Tier-2 live test).
- [ ] `SystemAudioAdapter.stop()` disposes the tap and aggregate device cleanly; no leftover
      `AudioDeviceID` registered with HAL.
- [ ] When the macOS default output device changes (e.g. headphones plugged in), audio capture
      continues without requiring user action or app restart (Tier-2 or manual test).
- [ ] Samples arrive in the mix target format (48 kHz / float32 / non-interleaved stereo) at the
      callback site; any format conversion happens inside the adapter, not in the caller.
- [ ] Tier-1 unit tests: `SystemAudioAdapter` is hidden behind an adapter protocol;
      `AudioPipeline` tests can inject a fake that emits known buffers.
- [ ] Existing Tier-1 tests continue to pass.

## Notes

- `AudioHardwareCreateProcessTap` requires macOS 14.4+ (same as the declared deployment target).
  Do not add a version guard — just fail gracefully if called on earlier OS.
- The aggregate device creation uses `AudioHardwareCreateAggregateDevice` with a dictionary that
  references the tap's device UID. See Apple's CATap sample and ADR 0004 for the exact key set.
- Rebinding on default-output change must not drop samples being actively consumed. The simplest
  safe approach: during the brief tap-recreate window, feed silence; the mix downstream absorbs it.
- Use `os_log` for all tap create / destroy / rebind events (matches the driver's logging convention).
- Screen-recording permission (`com.apple.security.screen-capture` entitlement or TCC prompt) may
  be required for the Process Tap. Confirm empirically on first build; document in infrastructure BC
  if a new entitlement is needed.

## Outcome

`SystemAudioAdapter` implemented in `Sources/AudioEngine/SystemAudioAdapter.swift`. Conforms to `UpstreamCaptureAdapter` (marked `@available(macOS 14.2, *)`). Key implementation details:

- `start()` / `stop()` on a serial `DispatchQueue`; all HAL lifecycle ops are serialised.
- Creates a `CATapDescription(stereoGlobalTapButExcludeProcesses: [])` global tap, then wraps it in an aggregate device via `AudioHardwareCreateAggregateDevice` with `kAudioAggregateDeviceTapListKey`.
- IOProc registered via `AudioDeviceCreateIOProcIDWithBlock`; each render cycle builds an `AVAudioPCMBuffer` in 48 kHz / float32 / non-interleaved stereo and calls `onBuffer`.
- Property listener on `kAudioHardwarePropertyDefaultOutputDevice` stored as `AudioObjectPropertyListenerBlock` and removed cleanly in `stop()`. On change: `tearDown()` + `setUp()` on the serial queue (silence during rebind window).
- `UpstreamCaptureAdapter` protocol extended with `var onBuffer: ((AVAudioPCMBuffer) -> Void)?` and changed to `AnyObject` constraint; `AudioPipeline` gained `onSystemAudioBuffer` / `onMicBuffer` properties that wire to adapter's `onBuffer` on `didSet`.
- `FakeUpstreamCaptureAdapter` in tests gained `emitBuffer(_:)` helper for Tier-1 pipeline mix tests.

8 new Tier-1 tests added; all 25 tests (18 AudioEngine + 7 DriverIPC) pass.

Tier-2 (live) and manual smoke tests remain to be run on a real Mac with macOS 14.4+.

Key files:
- `Sources/AudioEngine/SystemAudioAdapter.swift` — new
- `Sources/AudioEngine/UpstreamCaptureAdapter.swift` — extended with `onBuffer`
- `Sources/AudioEngine/AudioPipeline.swift` — added `onSystemAudioBuffer` / `onMicBuffer`
- `Tests/AudioEngineTests/AudioPipelineTests.swift` — 8 new tests + updated fake

## Verifier note (iteration 1)

REASONS:
- `.agentheim/contexts/audio-engine/INDEX.md` was flagged as modified — **this is a false positive**: the INDEX.md changes (doing-list/todo-list/counts) were made by the orchestrator as part of Phase 4 Step 1 (todo→doing transition before workers were dispatched), not by this worker. Confirmed by scoped git diff: INDEX.md was not in worker's FILE_LIST.
- `Package.swift` was flagged as modified with out-of-scope DriverIPC additions — **this is a false positive**: those Package.swift changes (DriverIPC library, DriverIPCTests target) were made by the infrastructure-008 worker running in parallel and are already committed at bb3e71a. This worker's FILE_LIST does not include Package.swift.

SUGGESTED_FIX:
Verify that the implementation (SystemAudioAdapter, UpstreamCaptureAdapter protocol, AudioPipeline buffer callbacks, tests) satisfies all acceptance criteria. Confirm you did not touch INDEX.md or add DriverIPC to Package.swift. If clean, move task back to done/ and return SUCCESS.

ITERATION_HINT: likely-fixable
