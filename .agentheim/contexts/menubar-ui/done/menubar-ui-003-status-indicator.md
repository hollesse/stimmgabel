---
id: menubar-ui-003
title: Status indicator — consumer attached state and current device names in the dropdown
status: done
type: feature
context: menubar-ui
created: 2026-06-05
completed: 2026-06-05
commit:
depends_on: [audio-engine-006]
blocks: []
tags: [status, consumer, device-name, swiftui, menubar, ui]
related_adrs: [0003, 0009]
related_research: []
prior_art: []
---

## Why

The user needs to know at a glance whether Stimmgabel is actively mixing (a consumer is reading)
and which physical devices are currently in use on each side. Without this, the app feels like a
black box — there is no feedback that anything is happening.

## What

Add a status section to the dropdown (above the mute toggles) that shows:

1. **Consumer status** — one of:
   - "Idle — no app reading" (no consumer attached)
   - "Active — [N] app reading" or simply "Active" (one or more consumers)

2. **Current device names** (only when active or after first start):
   - "Mic: [device name]" — e.g. "Mic: AirPods Pro"
   - "System audio: [device name]" — e.g. "System audio: MacBook Pro Speakers"

3. **Layout** (v1, minimal):
   ```
   ● Active                        ← or "○ Idle"
   Mic: AirPods Pro
   System audio: MacBook Pro Speakers
   ────────────────────────────────
   ✓ Mic
   ✓ System audio
   ────────────────────────────────
   Quit
   ```
   Grayed-out text for device names is fine; disabled menu items are acceptable for display-only rows.

The status is observed from `AudioPipeline` (or a projection type) — the UI does not reach into
CoreAudio directly. The `AudioPipeline` exposes:
- `@Published var consumerActive: Bool`
- `@Published var currentMicDeviceName: String`
- `@Published var currentSystemAudioDeviceName: String`

(These may already exist in skeleton form from the walking skeleton's state machine.)

## Acceptance criteria

- [ ] When no app is reading the virtual mic, the dropdown shows "Idle" (or equivalent).
- [ ] When an app opens the Stimmgabel input (e.g. QuickTime), the dropdown updates to "Active"
      within one second (manual Tier-3 test).
- [ ] The current mic device name and system-audio device name are shown correctly and update when
      the macOS default devices change (manual test: plug in headphones → device name updates).
- [ ] Device names come from `AudioPipeline` published properties — the UI does not call CoreAudio.
- [ ] Tier-1 unit test: a fake `AudioPipeline` emits `consumerActive = true`; the view model
      produces the correct display string.
- [ ] Existing Tier-1 tests continue to pass.

## Notes

- "N apps reading" is a nice-to-have; v1 "Active / Idle" binary is sufficient.
- The device name for the mic side is available via `kAudioDevicePropertyDeviceName` on the
  current `AudioDeviceID` (the `MicAdapter` should expose it as a property, see audio-engine-004
  notes).
- System-audio device name: the current default output device name, similarly.
- This task is intentionally thin — just the observable state projected into the UI. No CoreAudio
  calls, no new audio logic.
- ADR 0003: use SwiftUI `@ObservedObject` or `@StateObject` on the `AudioPipeline` ViewModel.

## Outcome

Status section added to the `MenuBarView` dropdown above the mute toggles. Shows consumer status ("● Active" / "○ Idle — no app reading") and current device names (mic and system audio), grayed-out as display-only rows.

Key files changed:
- `Sources/AudioEngine/UpstreamCaptureAdapter.swift` — added `deviceName: String` to protocol
- `Sources/AudioEngine/MicAdapter.swift` — implements `deviceName`; reads from `kAudioDevicePropertyDeviceName` in `openDevice()` / clears in `tearDown()`
- `Sources/AudioEngine/SystemAudioAdapter.swift` — same pattern for output device name
- `Sources/AudioEngine/AudioPipeline.swift` — added `consumerActive`, `currentMicDeviceName`, `currentSystemAudioDeviceName`, `deviceNamesDidChange`
- `Sources/MenubarUI/AppViewModel.swift` — exposes `consumerActive`, `consumerStatusDisplayString`, `currentMicDeviceName`, `currentSystemAudioDeviceName`; subscribes to `deviceNamesDidChange`
- `Sources/MenubarUI/MenuBarView.swift` — status section above mute toggles
- `Tests/MenubarUITests/AppViewModelTests.swift` — 6 new Tier-1 tests
- `Tests/AudioEngineTests/AudioPipelineTests.swift` — added `deviceName` to `FakeUpstreamCaptureAdapter`

All 66 tests passing.
