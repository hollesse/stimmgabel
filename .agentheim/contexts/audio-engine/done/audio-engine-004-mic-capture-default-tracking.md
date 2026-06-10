---
id: audio-engine-004
title: Mic capture — HAL IOProc on default input device, rebind on default-input change
status: done
type: feature
context: audio-engine
created: 2026-06-05
completed: 2026-06-05
commit:
depends_on: []
blocks: [audio-engine-005]
tags: [capture, coreaudio, hal, ioProc, mic, default-tracking, microphone]
related_adrs: [0006, 0009]
related_research: []
prior_art: [audio-engine-001]
---
> **⚠ Superseded** by [audio-engine-007](audio-engine-007-phase1-phase2-architectural-reset.md) — Phase 1/2 architectural reset (2026-06-08).


## Why

The mic side of the mix must source samples from the current macOS default input device and rebind
silently when that default changes — AirPods connected mid-meeting, USB mic swapped. ADR 0006
decided the mechanism: CoreAudio HAL directly, with `AudioDeviceCreateIOProcID` + property listener
on `kAudioHardwarePropertyDefaultInputDevice`.

## What

Implement a `MicAdapter` (or equivalent) in the `AudioEngine` Swift module that:

1. **Resolves and opens the default input device** — on `start()`, reads
   `kAudioObjectSystemObject` / `kAudioHardwarePropertyDefaultInputDevice` to get the current
   `AudioDeviceID`; registers an IOProc via `AudioDeviceCreateIOProcID`; calls `AudioDeviceStart`.

2. **Installs a default-device listener** — `AudioObjectAddPropertyListener` on
   `kAudioHardwarePropertyDefaultInputDevice`. On fire: stop current IOProc, dispose it, resolve
   new default, open and start a new IOProc — transparently, without interrupting the mix.

3. **Starts / stops on demand** — `start()` / `stop()` drive lazy activation (called by
   `AudioPipeline` when a consumer attaches / detaches). `stop()` disposes the IOProc and the
   property listener.

4. **Delivers samples** via a callback (or `AsyncStream`) to the `AudioPipeline` mix step as
   float32 buffers in the mix target format (48 kHz / float32 / stereo). If the mic delivers a
   different sample rate or channel count, convert via `AudioConverter`.

5. **Triggers the TCC microphone permission prompt** at first start via
   `AVCaptureDevice.requestAccess(for: .audio)` before opening the HAL IOProc. If permission is
   denied, `start()` fails with a clear error; the mic side contributes silence.

6. **Thread safety** — HAL property-listener callbacks fire on arbitrary threads. All state
   transitions (rebind, start, stop) are dispatched onto a single serial `DispatchQueue` owned
   by `MicAdapter`.

## Acceptance criteria

- [ ] `MicAdapter.start()` opens the current default input device and delivers non-silent buffers
      when a mic is active (manual integration test or Tier-2 live test).
- [ ] Changing the macOS default input device (e.g. Preferences → Sound → Input) causes the
      adapter to rebind without app restart; audio continues (Tier-2 or manual).
- [ ] `MicAdapter.stop()` disposes the IOProc and property listener cleanly; no dangling listeners.
- [ ] Samples arrive in the mix target format (48 kHz / float32 / stereo) at the callback site;
      format conversion happens inside the adapter.
- [ ] If microphone TCC permission is denied, `start()` returns an error and the adapter emits
      silence — it does not crash.
- [ ] Tier-1 unit tests: `MicAdapter` hidden behind an adapter protocol; `AudioPipeline` tests
      inject a fake.
- [ ] Existing Tier-1 tests continue to pass.

## Notes

- ADR 0006 explicitly rejected `AVAudioEngine` and `AVCaptureSession` — do not use them for
  capture. `AVCaptureDevice.requestAccess` for the TCC prompt is the only AVFoundation call allowed.
- The default-device rebind must be non-blocking for the mix consumer — during the brief
  device-switch window, deliver silence rather than blocking the audio thread.
- HAL property-listener thread affinity: Apple does not guarantee which thread the callback fires
  on. The serial queue is mandatory, not optional.
- Consider exposing the current device name (e.g. "AirPods Pro") to `AudioPipeline` so
  `menubar-ui` can display it. The name is readable via `kAudioDevicePropertyDeviceName`.

## Outcome

`MicAdapter` implemented in `Sources/AudioEngine/MicAdapter.swift`. Conforms to `UpstreamCaptureAdapter` (ADR 0009 seam). Key design:
- `start()` synchronously resolves TCC mic permission via `AVCaptureDevice.requestAccess` (semaphore-guarded); throws `MicAdapterError.permissionDenied` if denied.
- `start()` then resolves `kAudioHardwarePropertyDefaultInputDevice`, reads the device's native `AudioStreamBasicDescription`, builds an `AudioConverter` when the native format differs from the 48 kHz / float32 / stereo mix target, and registers an IOProc via `AudioDeviceCreateIOProcIDWithBlock`.
- `AudioObjectAddPropertyListenerBlock` on `kAudioHardwarePropertyDefaultInputDevice`; on fire dispatches a rebind onto the adapter's serial queue (tearDown + openDevice), delivering silence during the brief device-switch window.
- `stop()` disposes IOProc, AudioConverter, and property listener, all on the serial queue.
- 4 new Tier-1 tests added to `Tests/AudioEngineTests/AudioPipelineTests.swift`; all 22 tests pass.
