---
id: audio-engine-001
title: Decision — microphone capture & default-device tracking
status: done
type: decision
context: audio-engine
created: 2026-06-05
completed: 2026-06-05
commit:
depends_on: []
blocks: []
tags: [foundation, audio, coreaudio, default-tracking]
related_adrs: [0006]
related_research: []
prior_art: []
---

## Why
The "follows your system defaults" core promise lives or dies on how the audio-engine binds to the mic. The mechanism must allow rebinding on default-input changes without interrupting the downstream consumer reading from the virtual mic.

## What
Commit ADR 0006 capturing the architect's recommendation: capture the mic side via **CoreAudio HAL directly** (`AudioObjectAddPropertyListener` on `kAudioHardwarePropertyDefaultInputDevice`, `AudioDeviceCreateIOProcID` on the resolved device). AVAudioEngine and AVCaptureSession rejected because they hide the device identity that default-tracking requires.

This ADR is **BC-local to `audio-engine`** — neither `menubar-ui` nor `infrastructure` need to know about it. Indexes go under `<!-- adr-local:start -->` in `contexts/audio-engine/INDEX.md`, not under the global ADR list.

## Acceptance criteria
- [ ] `knowledge/decisions/0006-microphone-capture-and-default-device-tracking.md` exists with `scope: audio-engine`, `status: accepted`.
- [ ] `contexts/audio-engine/INDEX.md` updated under `<!-- adr-local:start -->`.
- [ ] No code changes.

## Notes

Architect draft (paste into the ADR with id `0006`, status `accepted`, date `2026-06-05`):

```markdown
---
id: 0006
title: Capture the mic side via CoreAudio HAL with property-listener-based default-device tracking
scope: audio-engine
status: accepted
date: 2026-06-05
supersedes: []
superseded_by: []
related_tasks: [audio-engine-001]
related_research: []
---

# ADR 0006: Capture the mic side via CoreAudio HAL with property-listener-based default-device tracking

## Context

The mic side of the mix must source samples from "whatever macOS currently considers the default input device" and **must rebind without user action** when that default changes (AirPods plugged in mid-meeting, USB mic swapped). The default-tracking promise is load-bearing for the product — see `vision.md` "What success looks like" and the `audio-engine` README ubiquitous-language entry for *default tracking*.

Available APIs:

- **AVAudioEngine / AVAudioSession.** High-level. Hides the underlying `AudioDeviceID` and tends to bind to "the system default" by abstraction rather than by an identity Stimmgabel can observe. Re-binding on default-change requires hacks.
- **AVFoundation `AVCaptureDevice` + `AVCaptureSession`.** Designed for media-capture pipelines. More device-aware than AVAudioEngine but still optimised for camera/mic capture in the AVFoundation graph shape, not for feeding samples into a CoreAudio Tap-based mix.
- **CoreAudio HAL directly** (`AudioObjectAddPropertyListener` on the system object's `kAudioHardwarePropertyDefaultInputDevice` property; `AudioDeviceCreateIOProcID` on the resolved device). Lowest level, exact match for the mental model in the audio-engine README.

## Decision

Capture the mic side via **CoreAudio HAL directly**, in the audio-engine BC:

- At consumer-attach time, resolve the current default input device by reading `kAudioObjectSystemObject` / `kAudioHardwarePropertyDefaultInputDevice` and open it with `AudioDeviceCreateIOProcID` + `AudioDeviceStart`.
- Install a property listener on `kAudioHardwarePropertyDefaultInputDevice` (on the system object). When it fires, stop and dispose the current IOProc, resolve the new default, and start a new IOProc on it — all without interrupting the downstream consumer (which is reading the *mix*, not the mic).
- The same pattern is reused by the system-audio side (see ADR 0004 / system-audio-capture) for `kAudioHardwarePropertyDefaultOutputDevice`.
- Use `AVCaptureDevice.requestAccess(for: .audio)` **only** to trigger the TCC microphone prompt at first run. Once granted, all actual capture flows through CoreAudio HAL.
- The mix is performed inside the app process at a fixed internal target (e.g. 48 kHz / float32 / stereo); per-side sample-rate and channel-count reconciliation happens inside the audio-engine via `AudioConverter` instances.

## Consequences

### Positive
- Direct match to the audio-engine README's ubiquitous language (`AudioDeviceID`, default tracking, IOProc).
- Re-binding on default-device change is a first-class API affordance, not a workaround.
- Lazy activation is precise: no IOProc registered → no capture → no mic indicator.
- The same mental model and code shape covers both the mic side and the system-audio side (which uses the analogous output-default listener).

### Negative
- Lower-level than AVFoundation: more C-shaped code paths, more careful retain/release / `AudioObjectID` lifecycle management. Requires Swift+CoreAudio interop discipline.
- We own the sample-rate conversion path. `AudioConverter` is well-trodden but is one more thing to test.
- The CoreAudio HAL property-listener callbacks fire on arbitrary threads; the audio-engine has to dispatch state transitions onto a single serial queue to keep invariants safe.

### Neutral
- This decision is BC-local to audio-engine; the menubar-ui and infrastructure BCs do not need to know which API was used.

## Alternatives considered

- **AVAudioEngine.** Rejected. Hides the underlying device identity that default-tracking requires. Re-binding on a default-input change ends up being a heuristic, not a contract.
- **AVCaptureSession.** Rejected. Optimised for AVFoundation media graphs; awkward to splice into a CoreAudio Tap + mix + Audio Server Plugin pipeline.
- **Pin the user's chosen device explicitly (let the user pick a mic in the dropdown).** Rejected — directly contradicts the "follows your system defaults" core promise (`vision.md`).

## References
- `audio-engine/README.md` — default tracking ubiquitous-language entry; aggregates DeviceWatcher invariant
- `vision.md` — "follows your system defaults" core promise
- Apple developer docs: CoreAudio HAL property listeners, `AudioDeviceCreateIOProcID`
```
