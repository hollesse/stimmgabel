---
id: audio-engine-008
title: Device names always visible — read system defaults independent of consumer attachment
status: done
type: feature
context: audio-engine
created: 2026-06-15
completed: 2026-06-15
commit: 7bd4d42
depends_on: []
blocks: []
tags: [device-names, hal, property-listener, ui-data]
related_adrs: [0006]
related_research: []
prior_art: [audio-engine-003, audio-engine-004, menubar-ui-003]
---

## Why

Today the dropdown shows `Mic: —` and `System audio: —` whenever no consumer
is attached, because `AudioPipeline.currentMicDeviceName` /
`currentSystemAudioDeviceName` are only populated when a capture adapter
actually starts. The names were tied to "what we're recording from", not
"what the system default device currently is".

The user wants the menu-bar dropdown to always show *which mic and which
output Stimmgabel will use* — so they can verify the routing at a glance,
even when no app is reading from the virtual mic.

## What

Introduce a `DefaultDeviceMonitor` inside `audio-engine` that:

1. Reads the current default input and default output device names on init
   (HAL `kAudioHardwarePropertyDefaultInputDevice` +
   `kAudioObjectPropertyElementMain` →
   `kAudioDevicePropertyDeviceName`).
2. Installs CoreAudio property listeners on both `kAudioHardwarePropertyDefaultInputDevice`
   and `kAudioHardwarePropertyDefaultOutputDevice` so name changes (e.g. plug
   in AirPods, switch built-in mic) fire a callback within 1–2 s.
3. Exposes `currentMicDeviceName: String` and
   `currentSystemAudioDeviceName: String` (empty string if no default device).

`AudioPipeline` holds one `DefaultDeviceMonitor` and delegates
`currentMicDeviceName` / `currentSystemAudioDeviceName` to it instead of
storing local `_micName` / `_sysName` populated only on
`consumerAttached()`. The existing `deviceNamesDidChange` callback fires
when the monitor reports a change.

`MenuBarView` does not need to change — it already reads via `AppViewModel`
and renders `—` for empty strings (kept as edge case for "no default
device at all", which is rare but possible).

### Existing helpers to reuse

`MicAdapter.readDefaultInputDeviceName()` already implements the HAL read
for input. Refactor it out of `MicAdapter` into the new
`DefaultDeviceMonitor` (or a small free helper) so both monitor and adapter
share one implementation. The analogous output-side read is new — same
pattern with `kAudioHardwarePropertyDefaultOutputDevice`.

## Acceptance criteria

- [ ] Mic and System-audio device names are visible in the dropdown when
      pipeline state is `idle` (no consumer attached)
- [ ] Switching the system default input mid-session (e.g. plug/unplug
      AirPods) updates the displayed name within ~2 s without restarting
      the app
- [ ] Same for default output / system audio
- [ ] When a consumer attaches, the displayed names are still correct
      (no regression vs. menubar-ui-003 behaviour)
- [ ] Names are empty string only when no default device exists (rare —
      e.g. no audio hardware); `MenuBarView` renders `—` in that case
- [ ] Tests green; new unit tests cover monitor read + property-listener
      callback wiring (with a fake HAL where feasible, or live HAL on the
      developer Mac if the testing strategy permits)

## Notes

- ADR 0006 already established HAL + property-listener-based default-device
  tracking for the mic side — this task extends the same pattern to also
  feed the UI, and adds the output side.
- No new ADR expected: this is implementation of an existing decision plus
  trivial symmetry on the output side.
- After this lands, the field `_micName` / `_sysName` in `AudioPipeline`
  becomes dead — clean up alongside the change.
- File-based debug log `~/Library/Logs/Stimmgabel-debug.log` already exists
  from the mic-capture fix; one or two `debugLog()` lines on default-device
  change can help observability without polluting Console.app.

## Outcome

Added `DefaultDeviceMonitor` (`Sources/AudioEngine/DefaultDeviceMonitor.swift`)
— a process-lifetime observer of `kAudioHardwarePropertyDefaultInputDevice`
and `kAudioHardwarePropertyDefaultOutputDevice` on `kAudioObjectSystemObject`.
It reads both device names eagerly on init and installs
`AudioObjectAddPropertyListenerBlock` listeners on a serial dispatch queue;
on fire it re-reads the affected name and invokes `onChange`. Names are
exposed via `currentMicDeviceName` / `currentSystemAudioDeviceName`.

`AudioPipeline` now holds one `DefaultDeviceMonitor`, delegates the two name
properties to it, and forwards the monitor's `onChange` to its own
`deviceNamesDidChange`. The local `_micName` / `_sysName` fields are gone;
`consumerAttached()` / `consumerDetached()` no longer write to them. A new
parameter `deviceMonitor: DefaultDeviceMonitor = DefaultDeviceMonitor()` lets
tests inject a deterministic monitor.

`MicAdapter.readDefaultInputDeviceName()` was removed; both call sites now
use the shared free function `readDefaultDeviceName(forSelector:)` in
`DefaultDeviceMonitor.swift`.

`MenuBarView` is unchanged — it already renders `—` for empty strings.
`AppViewModel` is unchanged in shape; its existing `deviceNamesDidChange`
subscription is now driven by the monitor.

### Key files
- `Sources/AudioEngine/DefaultDeviceMonitor.swift` (new)
- `Sources/AudioEngine/AudioPipeline.swift` (delegates names, accepts monitor in init)
- `Sources/AudioEngine/MicAdapter.swift` (uses shared helper)
- `Tests/AudioEngineTests/DefaultDeviceMonitorTests.swift` (new — 12 tests)
- `Tests/MenubarUITests/AppViewModelTests.swift` (updated for removed setter)
- `.agentheim/contexts/audio-engine/README.md` (new ubiquitous-language entry, new component row)

### Tests
All 87 tests pass (`swift test`). 12 new tests cover: free-helper read on
live HAL, init eager-read, deterministic test initializer, onChange wiring
for mic / sys / no-change, refresh-vs-live consistency, deinit safety,
pipeline-delegates-to-monitor in idle and consumer-attached states.

### Notes
No new ADR — this is implementation of ADR 0006 extended symmetrically to
the output side, as anticipated in the task notes. The
`_micName` / `_sysName` cleanup mentioned in the Notes section is done.
