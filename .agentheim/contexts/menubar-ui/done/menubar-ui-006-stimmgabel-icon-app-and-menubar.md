---
id: menubar-ui-006
title: Stimmgabel icon — designed colourful app icon + tuning-fork menubar icon with active-state waves
status: done
type: feature
context: menubar-ui
created: 2026-06-16
completed: 2026-06-16
commit:
depends_on: []
blocks: []
tags: [icon, app-icon, menubar, branding, asset-catalog]
related_adrs: []
related_research: []
prior_art: [menubar-ui-003]
---

## Why

The app and the menu-bar icon currently use generic SF Symbols
(`waveform.slash` / `waveform`). They give zero brand identity — in the
Dock, in the menu bar, in Mission Control, Stimmgabel looks like every
other audio utility. The name itself ("Stimmgabel" = tuning fork in
German, see `vision.md` for the pun) begs a tuning-fork visual.

The active-state should be visually obvious at a glance — a consumer is
attached → the fork is "struck" and emitting sound. Wifi-style arc waves
on both sides of the tuning fork's prongs make that legible without an
animation.

## What

Two visual artefacts integrated into the macOS build:

### A. App icon (Dock / Finder / Mission Control)

- **Style:** designed, colourful, classic macOS app-icon look. Squircle
  background (let macOS handle the rounding by providing a full-square
  PNG — macOS 11+ applies the squircle shape automatically). Tuning fork
  as the central element, ideally with a metallic / gradient finish
  hinting at the "Stimmgabel struck → sound" idea.
- **Single state.** App icons do not change with runtime state — only
  the menu-bar icon reflects idle vs. active.
- **All required sizes** generated and added to the Asset Catalog's
  `AppIcon` set: 16, 32, 64, 128, 256, 512, 1024 px in both 1x and 2x.
  `iconutil` from a `.iconset` directory is the canonical macOS
  generation path; `sips` can resize a single 1024×1024 source.

### B. Menu-bar icon (the `MenuBarExtra` label)

- **Style:** monochrome template image. The macOS menu bar tints
  template images automatically (dark/light + selected/unselected). The
  asset MUST be marked as a Template image in the Asset Catalog
  (`templateRenderingIntent`).
- **Two states only** (matching the current pipeline state machine after
  audio-engine-007 removed mute from the UI):
  - `idle` (`pipelineState == .idle`): tuning fork alone
  - `active` (`pipelineState == .consumerAttached`): tuning fork PLUS
    sound-wave arcs on both prongs. Reference visual: similar arc style
    to the macOS Wi-Fi symbol's arcs, applied symmetrically to the left
    and right of the fork's body.
- **Static.** Waves are baked into the active-state image; no animation
  framework. Apple HIG recommends static menu-bar icons.
- **Size:** menu-bar items render at ~18×18 pt. Provide @1x / @2x / @3x
  PDF or PNG. PDF is preferred for clean tinting at any scale.

### C. Artwork sourcing — worker's path

The worker finds a freely-licensed tuning-fork vector and builds both
icon variants on top of it. Acceptable licences (in order of preference):

1. **Public Domain / CC0** — no attribution required, no restrictions.
   Best for a small project.
2. **CC-BY** — attribution required in a `LICENSES.md` or similar file.
3. **OFL / MIT / Apache** — also fine, attribute per the licence.
4. **Avoid:** anything CC-BY-NC (the project is not commercial today but
   may be later, and the licence cost of swapping later is real); also
   avoid CC-BY-SA (forces the project's icon-derived works under
   share-alike).

Suggested sources to check first:
- SVGRepo's "Public Domain" filter
- The Noun Project (CC-BY entries; attribution requirement noted)
- Wikimedia Commons (mixed licences; tuning-fork SVGs exist there)
- Iconoir / Tabler / Lucide (MIT-licensed, but may not have a tuning
  fork specifically — check before assuming)

The active-state waves do NOT need to come from the same source — they
can be hand-authored arcs added to the base tuning-fork vector. The
worker is free to compose.

### D. Integration into the build

1. Create `App/Stimmgabel/Assets.xcassets/` (or wherever the Xcode app
   target expects asset catalogues — confirm the existing target layout).
   The catalogue does NOT exist today; this task creates it.
2. Add `AppIcon.appiconset` with all sizes.
3. Add a menu-bar icon image set — suggested names: `MenubarIdle` and
   `MenubarActive`. Both marked as **Template Image** in their JSON.
4. Update the Xcode app target's `ASSETCATALOG_COMPILER_APPICON_NAME`
   build setting (or the project.pbxproj equivalent) so the app uses the
   new `AppIcon`.
5. Update `Sources/MenubarUI/StimmgabelApp.swift`: change the
   `MenuBarExtra` label from `Image(systemName: viewModel.menuBarIconName)`
   to `Image(viewModel.menuBarIconName)` (drop `systemName:`).
6. Update `Sources/MenubarUI/AppViewModel.swift`:
   `menuBarIconName` currently returns `"waveform.slash"` / `"waveform"`.
   Change to return the new asset names: `"MenubarIdle"` /
   `"MenubarActive"`.
7. Add a `LICENSES.md` (or extend an existing one if present) attributing
   the source SVG per its licence, with the URL it was downloaded from.

### E. Test impact

- `swift test` for the existing unit tests should stay green —
  `menuBarIconName` is a string property, the unit tests don't assert
  against the specific SF-Symbol names beyond what the worker can fix in
  one or two assertions.
- If `AppViewModelTests.swift` has assertions like
  `XCTAssertEqual(vm.menuBarIconName, "waveform")`, update them to the
  new asset names. Do not remove the test — the wiring is exactly what
  the test guards.

## Acceptance criteria

- [ ] `App/Stimmgabel/Assets.xcassets/AppIcon.appiconset` exists with
      all required sizes (16/32/64/128/256/512/1024 × 1x/2x)
- [ ] The Xcode target builds with the new AppIcon; after
      `./script/build` the resulting `dist/Stimmgabel.app/Contents/Resources/AppIcon.icns`
      shows the tuning-fork icon (verifiable by `iconutil -c iconset` or
      opening the .app in Finder)
- [ ] Asset catalog also contains `MenubarIdle` and `MenubarActive`
      image sets, both marked as Template Image
- [ ] When the app runs idle, the menu bar shows the tuning-fork icon
      (plain, no waves)
- [ ] When a consumer attaches (e.g. open QuickTime → New Audio Recording
      → select Stimmgabel), the menu-bar icon changes to the
      tuning-fork-with-waves variant within one render cycle
- [ ] Menu-bar icon tints correctly in both light and dark mode and in
      the selected (highlighted) state — proves the Template Image flag
      is set correctly
- [ ] `LICENSES.md` (or equivalent attribution file in the repo) names
      the source of the SVG and its licence, with the URL it was taken
      from
- [ ] `swift test` stays green (any `menuBarIconName` assertions are
      updated to the new asset names — semantic test stays intact)
- [ ] No new compile warnings in the menubar-ui module

## Notes

### Out of scope

- **Animated active state.** Chosen statically — Apple HIG advice +
  battery drain concerns. If we ever want pulsing waves, capture as a
  follow-up.
- **Level-reactive icon variants** (small / medium / loud waves driven
  by mic peak). Briefly considered, rejected for v1 — three icon assets
  + peak-detection path is too much work for marginal value.
- **Custom muted-side icon.** Mute UI was removed in audio-engine-007;
  no muted state exists. If mute returns in a future Phase 3, this task
  will need a follow-up to add a third icon variant.
- **In-app About / icon credits screen.** Out of scope. Attribution
  lives in `LICENSES.md` only. If users care about provenance, they
  read that file in the repo.

### Implementation hints

- **PDF vs PNG for menubar:** macOS renders PDF assets as vectors at any
  scale, which avoids fuzziness on retina. For the two menu-bar icons,
  prefer PDF if the source SVG converts cleanly (Preview can save
  SVG-imported-into-Preview as PDF; or use `rsvg-convert`).
- **App icon:** Apple's recommended source is a single 1024×1024 PNG
  with the design centred and bleeding to the edges; macOS applies the
  squircle mask. Do NOT pre-round the corners — let the system do it.
- **Template Image flag** is set in the Asset Catalog's `Contents.json`
  for each image set: add `"template-rendering-intent" : "template"`.
- **The .xcassets file lives inside the Xcode app target's source
  folder.** Check the existing `App/Stimmgabel/` layout from the
  walking skeleton (infrastructure-006) to confirm the path. If
  unclear, place at `App/Stimmgabel/Assets.xcassets/` and add it to the
  Stimmgabel target via project.pbxproj.

### Prior-art note

`menubar-ui-003` (status indicator) established the icon-state-from-
pipelineState pattern. This task does not change that pattern — it
only swaps the SF Symbol asset names for custom asset names. Same
plumbing.

### A hint about acceptance criterion #5 (active state)

To verify the active-state icon manually: install the app + driver,
then open `Audio MIDI Setup.app` or QuickTime and select Stimmgabel as
the audio input source. That triggers `consumerAttached` and the icon
should flip. (No need for a real recording app — anything that "opens"
the Stimmgabel input device counts.)

## Outcome

Stimmgabel now has its own brand identity in both the menu bar and the
Dock.

**Custom artwork** — hand-authored SVGs (project-original, CC0):
- `art/tuning-fork-base.svg` — reusable base shape (rounded U-fork + handle)
- `art/menubar-idle.svg`     — monochrome menubar icon, idle state
- `art/menubar-active.svg`   — monochrome menubar icon, active state (fork
  plus symmetric Wi-Fi-style sound-wave arcs on both sides)
- `art/appicon-1024.svg`     — colourful designed app icon: deep-blue radial
  background, silver-gradient tuning fork with specular highlights and a
  drop shadow, faint luminous resonance rings, and outer sound-wave arcs

**Asset Catalog (new in this task)** at `App/Stimmgabel/Assets.xcassets/`:
- `AppIcon.appiconset` — full 16/32/64/128/256/512/1024 px × @1x/@2x PNG ladder
- `MenubarIdle.imageset` and `MenubarActive.imageset` — PDF vector
  representations, marked Template Image (so AppKit tints per
  light/dark/selected automatically)

**Build integration**:
- `App/Stimmgabel.xcodeproj/project.pbxproj`:
  - added a `PBXFileReference` and `PBXBuildFile` for `Assets.xcassets`
  - new `PBXResourcesBuildPhase` on the Stimmgabel target
  - both target configs gain `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`
    and `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS = YES`
- Verified by `xcodebuild`: the built `Stimmgabel.app/Contents/Resources/`
  contains both `AppIcon.icns` (with the tuning-fork artwork at the
  embedded sizes) and `Assets.car` (with `AppIcon`, `MenubarIdle`,
  `MenubarActive`, the last two confirmed `"Template Mode" : "template"`)

**Code wiring**:
- `Sources/MenubarUI/AppViewModel.swift` — `menuBarIconName` now returns
  `"MenubarIdle"` / `"MenubarActive"` (was `"waveform.slash"` /
  `"waveform"`)
- `Sources/MenubarUI/StimmgabelApp.swift` — `MenuBarExtra` label switched
  from `Image(systemName:)` to `Image(_:)` to pull from the Asset Catalog
- `Tests/MenubarUITests/AppViewModelTests.swift` — two icon assertions
  updated to the new asset names; semantics of the tests unchanged

**Attribution**: New top-level `LICENSES.md` documents the artwork as
project-original CC0.

**Tests**: `swift test` — 87 tests pass, 1 skipped, 0 failures.

**Acceptance criteria — status**:
- [x] AppIcon.appiconset with full size ladder (verified in built app)
- [x] Built `Stimmgabel.app/Contents/Resources/AppIcon.icns` shows the
      tuning fork (verified via `iconutil -c iconset`)
- [x] `MenubarIdle` and `MenubarActive` image sets present, both Template
      Mode confirmed in compiled `Assets.car`
- [x] Idle state uses plain tuning-fork (idle→`MenubarIdle` plumbed)
- [x] Active state uses fork+waves (active→`MenubarActive` plumbed)
- [x] Template images — tinting handled by AppKit via the template flag
- [x] `LICENSES.md` present at repo root
- [x] `swift test` green; icon assertions updated
- [x] No new compile warnings in MenubarUI (build output clean)

**Manual smoke test (acceptance #5 — author task)**: build, install, open
QuickTime → New Audio Recording → select Stimmgabel → confirm the menubar
icon flips from plain fork to fork-with-waves within one render cycle.
