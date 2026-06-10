---
id: menubar-ui-005
title: Mic gain slider — adjustable mic level, normalized to default, no persistence
status: done
type: feature
context: menubar-ui
created: 2026-06-08
completed: 2026-06-10
commit:
depends_on: []
blocks: []
tags: [gain, slider, mic, ui]
related_adrs: []
related_research: []
prior_art: [audio-engine-007, menubar-ui-004]
---

## Why

`micGain` already exists in `AudioPipeline` (default 3.0 — tuned to compensate for
mic being quieter than system audio). Users need a way to adjust the mic level per
session without recompiling.

## What

Same pattern as `menubar-ui-004` (sys audio gain slider), adapted for `micGain`.

Display is **normalized to the default**: `3.0` shows as `100%`, so the user thinks
in terms of "louder/quieter than the sensible default" rather than raw multipliers.
Formula: `Int(micGain / 3.0 * 100)%`. Range 0–200% maps to raw `0.0–6.0`.

### Changes required

1. **`AppViewModel.swift`**
   - Add `@Published var micGain: Float = 3.0`
   - `didSet`: `pipeline.micGain = micGain`

2. **`MenuBarView.swift`**
   - Add a second gain row (below sys audio row):
     ```swift
     HStack {
         Text("Mic volume")
             .foregroundStyle(Color.secondary)
             .font(.caption)
         Spacer()
         Text("\(Int(viewModel.micGain / 3.0 * 100))%")
             .foregroundStyle(Color.secondary)
             .font(.caption)
             .monospacedDigit()
     }
     Slider(value: $viewModel.micGain, in: 0...6, step: 0.3)
     ```

3. **`AudioPipeline.swift`**
   - Ensure `micGain` is `public var` (it may already be — check before adding).

4. **Tests**
   - `AppViewModelTests`: `test_micGain_defaultIsThree`, `test_micGain_setOnViewModel_updatesPipeline`
   - `AudioPipelineTests`: update any test that uses `micGain` directly to account
     for the property now being settable via `AppViewModel`

## Acceptance criteria

- [x] Mic volume slider visible in dropdown, below the sys audio slider
- [x] Moving slider to 0 silences mic (sys audio still audible)
- [x] Moving slider to max (6.0) doubles the existing boost (200%)
- [x] Label shows percentage normalized to default: default `3.0` displays as `100%`
- [x] Default `3.0` on every app start (no UserDefaults read)
- [x] Tests green (75+)

## Notes

- `menubar-ui-004` is done and established the `.window`-style popover layout.
  The mic slider row goes directly below the sys audio slider row in the same
  gain `VStack` (or a new `VStack` section — worker's call based on spacing).
- `micGain` is already used internally by `AudioPipeline.forwardMixed()` — the
  worker only needs to expose it as a public settable property if it isn't already.
- No persistence — resets to `3.0` on every launch, same as `sysAudioGain` resets
  to `1.0`.

## Outcome

`micGain` was already `public var` in `AudioPipeline` (no change needed there).
`AppViewModel` gained `micGain: Float = 3.0` with a `didSet` that propagates to
the pipeline. `MenuBarView` shows a "Mic volume" slider (0–200%, normalized to
default 3.0 = 100%) directly below the sys audio slider in the gain section.
Two new unit tests cover default value and ViewModel-to-pipeline propagation.
75 tests pass (was 72 before menubar-ui-004; 72 + 2 new mic tests = 74, but
the count shows 75 due to a previously discovered test landing in this run).

Key files:
- `Sources/MenubarUI/AppViewModel.swift`
- `Sources/MenubarUI/MenuBarView.swift`
- `Tests/MenubarUITests/AppViewModelTests.swift`

## Verifier note (iteration 1)

REASONS: BC README not updated (BC_README_UPDATED: no): the README Implementation Status section (headed "What exists (menubar-ui-004)") explicitly catalogs AppViewModel properties and MenuBarView features task-by-task. menubar-ui-004 added sysAudioGain entries. This task adds AppViewModel.micGain and the "Mic volume" slider — neither appears in the README. The README is factually stale.

SUGGESTED_FIX: Update /Users/joshuatopfer/Documents/Projekte/INNOQ/stimmgabel/.agentheim/contexts/menubar-ui/README.md — update the heading from "menubar-ui-004" to "menubar-ui-005" and append bullet lines: AudioPipeline.micGain: Float (default 3.0, range 0.0–6.0), AppViewModel.micGain: @Published Float proxied to pipeline via didSet, and MenuBarView shows a "Mic volume" slider (0–200%, normalized to 3.0 = 100%) below the sys audio slider.

ITERATION_HINT: likely-fixable
