---
id: menubar-ui-005
title: Mic gain slider — adjustable mic level, no persistence
status: backlog
type: feature
context: menubar-ui
created: 2026-06-08
completed:
commit:
depends_on: [menubar-ui-004]
blocks: []
tags: [gain, slider, mic, ui]
related_adrs: []
related_research: []
prior_art: [audio-engine-007]
---

## Why

`micGain` already exists in `AudioPipeline` (default 3.0).  Users need a slider
to adjust the mic level per session without recompiling.

## What

Identical pattern to menubar-ui-004 (sys audio gain slider), but for `micGain`.
Add a second `Slider` in `MenuBarView` below the system audio slider.

### Changes required

1. **`AppViewModel.swift`** — `@Published var micGain: Float = 3.0` with `didSet`
2. **`MenuBarView.swift`** — second `Slider(value: $viewModel.micGain, in: 0...10)`
3. **Tests** — update test that checks micGain-dependent output

## Acceptance criteria

- [ ] Mic slider visible in dropdown below sys audio slider
- [ ] Moving to 0 silences mic (sys audio still audible)
- [ ] Default 3.0 on every app start
- [ ] Tests green

## Notes

Depends on menubar-ui-004 to establish the slider pattern first.
