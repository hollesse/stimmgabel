---
id: menubar-ui-004
title: System audio gain slider — adjustable output level, no persistence
status: todo
type: feature
context: menubar-ui
created: 2026-06-08
completed:
commit:
depends_on: []
blocks: [menubar-ui-005]
tags: [gain, slider, sys-audio, ui]
related_adrs: []
related_research: []
prior_art: [audio-engine-007]
---

## Why

The system audio tap captures at whatever the macOS system volume is set to.
Users need a quick way to balance the system audio level relative to their mic
without leaving the recording app.  No persistence is needed — the default is
sensible and users can adjust per session.

## What

Add a `sysAudioGain: Float` property to `AudioPipeline` (default 1.0, range
0.0–2.0) that is applied in `forwardMixed()` to the system audio channels.
Expose it via `AppViewModel` and wire it to a `Slider` in `MenuBarView`.

### Changes required

1. **`AudioPipeline.swift`**
   - Add `public var sysAudioGain: Float = 1.0`
   - Apply in `forwardMixed()`: `sysL[i] * sysAudioGain + micSamples[i*2] * micGain`

2. **`AppViewModel.swift`**
   - Add `@Published var sysAudioGain: Float = 1.0`
   - On `didSet`: `pipeline.sysAudioGain = sysAudioGain`

3. **`MenuBarView.swift`**
   - Add a `Slider(value: $viewModel.sysAudioGain, in: 0...2, step: 0.1)` with label

4. **Tests**
   - Update `test_sysAudio_reachesOutput` to account for `sysAudioGain`
   - Add `test_sysAudioGain_appliedToOutput`

## Acceptance criteria

- [ ] Slider visible in menu bar dropdown when consumer is active
- [ ] Moving slider to 0.0 silences system audio (mic still audible)
- [ ] Moving slider to 2.0 doubles system audio amplitude
- [ ] Default 1.0 on every app start (no UserDefaults read)
- [ ] Tests green (68+)

## Notes

- Pattern is identical to `micGain` which already exists — minimal effort.
- Range 0.0–2.0 is intentional: > 1.0 allows boosting quiet content.
- Mic slider (menubar-ui-005) follows the same pattern after this lands.
