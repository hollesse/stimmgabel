---
id: menubar-ui-007
title: Swap icon artwork — adopt Claude Design handoff for app + menubar icons
status: done
type: chore
context: menubar-ui
created: 2026-06-17
completed: 2026-06-17
commit:
depends_on: []
blocks: []
tags: [icon, app-icon, menubar, branding, asset-catalog]
related_adrs: []
related_research: []
prior_art: [menubar-ui-006]
---

## Why

menubar-ui-006 shipped the first generation of the Stimmgabel icon set
(hand-authored SVGs, full pipeline wired through the Asset Catalog into
`Stimmgabel.app`). The user has since received a refined design pass
from Claude Design and dropped the handoff under
`docs/Stimmgabel-Icons-Designs/`. The new artwork is the canonical
direction — cleaner U-fork geometry with a foot circle, polished
chrome-on-blue app icon with glowing cyan resonance waves, and
tightened monochrome menubar templates.

The plumbing from menubar-ui-006 stays exactly as is. This is an
asset-only swap plus the standard regeneration of derived files (PNG
ladder, PDFs, `.icns`). No code in `Sources/` changes.

## What

Adopt the four SVGs from `docs/Stimmgabel-Icons-Designs/art/` as the
new sources of truth in `art/`, then regenerate all derived assets in
`App/Stimmgabel/Assets.xcassets/`.

### A. Replace source SVGs

Overwrite the four files in `art/` with the handoff versions from
`docs/Stimmgabel-Icons-Designs/art/`:

- `art/tuning-fork-base.svg`     ← reusable base shape
- `art/menubar-idle.svg`         ← monochrome template, idle state
- `art/menubar-active.svg`       ← monochrome template, active state
- `art/appicon-1024.svg`         ← colourful app icon (blue radial bg,
  chrome tuning fork, glowing cyan wave arcs)

Note: the handoff menubar SVGs use a 1024×1024 viewBox with solid
`fill="#000000"` (the old ones used a 100×100 viewBox with
`currentColor`). Both work as Template Images — AppKit tints based on
alpha, not fill colour. No change to the imageset `Contents.json` is
needed.

### B. Regenerate derived assets

1. **AppIcon PNG ladder** (`App/Stimmgabel/Assets.xcassets/AppIcon.appiconset/`):
   render `art/appicon-1024.svg` to PNGs for all sizes listed in the
   appiconset's `Contents.json` — 16/32/64/128/256/512/1024 px ×
   @1x/@2x. `rsvg-convert` or `qlmanage`/`sips` from a 1024 source both
   work; whatever menubar-ui-006 used should be reused.

2. **Menubar PDFs** (`App/Stimmgabel/Assets.xcassets/MenubarIdle.imageset/`
   and `MenubarActive.imageset/`): re-export the two menubar SVGs as PDF
   (vector). `rsvg-convert -f pdf` or Preview's "Export as PDF" both
   produce clean output. Keep the existing filenames so `Contents.json`
   doesn't need to be edited.

3. **`.icns`**: regenerated automatically by `xcodebuild` from the
   AppIcon appiconset — no manual `iconutil` step required if the
   PNGs are in place.

### C. Keep top-level `art/AppIcon.iconset/` and `art/AppIcon.icns` in sync

menubar-ui-006 also produced a working copy at `art/AppIcon.iconset/`
and a compiled `art/AppIcon.icns`. Regenerate both so the repo-level
artefacts match the new design.

### D. Attribution

`LICENSES.md` already attributes the icon artwork as project-original
CC0. The handoff is also project-original (Claude Design, on
commission for this project). No licence change. Update the file only
if the wording needs to mention the design-handoff lineage —
optional, low priority.

### E. Keep the handoff folder

`docs/Stimmgabel-Icons-Designs/` (SVGs, screenshots, the two `.dc.html`
walkthroughs) stays in the repo as design history. Do not delete it —
it's the provenance for the new artwork.

## Acceptance criteria

- [ ] The four SVGs in `art/` are byte-identical to those in
      `docs/Stimmgabel-Icons-Designs/art/`
- [ ] `App/Stimmgabel/Assets.xcassets/AppIcon.appiconset/` contains a
      full regenerated PNG ladder rendered from the new
      `art/appicon-1024.svg` (visual spot-check: the icon shows the
      chrome fork on a blue radial background with cyan resonance arcs)
- [ ] `App/Stimmgabel/Assets.xcassets/MenubarIdle.imageset/` and
      `MenubarActive.imageset/` contain PDFs regenerated from the new
      menubar SVGs; both imageset `Contents.json` files still declare
      `"template-rendering-intent" : "template"`
- [ ] `art/AppIcon.iconset/` and `art/AppIcon.icns` regenerated to
      match the new design
- [ ] `xcodebuild` succeeds; the resulting
      `Stimmgabel.app/Contents/Resources/AppIcon.icns` shows the new
      app icon (visual spot-check in Finder)
- [ ] Running the app: menubar shows the new idle fork; attaching a
      consumer (QuickTime → New Audio Recording → select Stimmgabel)
      flips the menubar icon to the new active fork-with-waves variant
      within one render cycle
- [ ] Menubar icon tints correctly in both light and dark mode (Template
      Image flag still effective)
- [ ] `swift test` stays green — no test changes expected (asset names
      `MenubarIdle` / `MenubarActive` and `AppIcon` are unchanged from
      menubar-ui-006, so `AppViewModelTests.swift` keeps passing as is)
- [ ] No new compile warnings in the MenubarUI module

## Notes

### Out of scope

- **Any code changes in `Sources/`.** The `MenuBarExtra` label, the
  `menuBarIconName` mapping, and the pipeline-state plumbing all stay
  exactly as menubar-ui-006 left them. If the worker thinks code needs
  to change, that's a sign something is off — stop and re-read.
- **Splitting the menubar icon into multi-resolution PDFs.** A single
  PDF per state is enough; PDFs are vector and AppKit scales them.
- **Animation, level-reactive variants, mute-state icon.** Same exclusions
  as menubar-ui-006 — explicitly out.
- **Touching `docs/Stimmgabel-Icons-Designs/`.** Keep as-is; it's the
  design provenance.

### Implementation hints

- The handoff `appicon-1024.svg` uses gradients, filters (drop shadow,
  Gaussian blur for the glow), and a feMerge. Rasterizers vary in
  filter support — `rsvg-convert` handles these well; `sips` cannot
  rasterise SVG directly, so use `rsvg-convert` to produce 1024×1024
  first, then `sips -z` for the smaller sizes from the rendered PNG.
- Confirm the PDF output for the menubar icons stays crisp at 18×18 pt
  by opening the built app on a non-retina display if one is around.
  If kerning/edges look off, fall back to PNG @1x/@2x/@3x — but PDF
  is the menubar-ui-006 baseline and should keep working.
- A diff of `art/menubar-idle.svg` before/after will be large because
  the viewBox changes from 100×100 to 1024×1024. That's expected.

### Prior-art note

menubar-ui-006 is the direct precursor — it built the entire icon
pipeline (Asset Catalog, project.pbxproj changes, AppViewModel
wiring). This task only swaps the artwork at the source. Read its
"Outcome" section for the exact path of every derived file that needs
regenerating.

## Outcome

Pure asset-only swap, exactly as scoped — no Sources/, no pbxproj, no
Contents.json edits.

**Source SVGs** — overwritten in `art/` byte-identical from
`docs/Stimmgabel-Icons-Designs/art/`:
- `art/tuning-fork-base.svg`
- `art/menubar-idle.svg` (now 1024×1024 viewBox with solid `fill="#000000"`)
- `art/menubar-active.svg` (same)
- `art/appicon-1024.svg` (chrome fork on blue radial bg, cyan resonance arcs)

**Rasteriser**: `rsvg-convert` (librsvg 2.62.1) — handles the appicon's
gradients / filters / feMerge cleanly. Each PNG rendered directly from
the 1024 source at its target pixel size (no `sips` downscaling step
needed at these sizes; quality is good).

**AppIcon PNG ladder** — regenerated at
`App/Stimmgabel/Assets.xcassets/AppIcon.appiconset/` for the ten sizes
declared in `Contents.json` (16/32/128/256/512 × @1x/@2x). `Contents.json`
untouched.

**Menubar PDFs** — re-exported via `rsvg-convert -f pdf` at
`App/Stimmgabel/Assets.xcassets/MenubarIdle.imageset/menubar-idle.pdf`
and `MenubarActive.imageset/menubar-active.pdf`. Both imageset
`Contents.json` files still declare
`"template-rendering-intent" : "template"` and
`"preserves-vector-representation" : true` (untouched).

**Repo-level mirror** — `art/AppIcon.iconset/` (10 PNGs) and
`art/AppIcon.icns` (745.4K from `iconutil -c icns`) regenerated to
match the new design.

**Verification**:
- `swift test` — 87 tests pass, 1 skipped, 0 failures (no test changes,
  asset names unchanged from menubar-ui-006).
- `./script/build` — succeeds; built
  `.build/xcodebuild/Stimmgabel.app/Contents/Resources/` contains
  `AppIcon.icns` (81.9K, Xcode-compiled) and `Assets.car` with
  `MenubarIdle`, `MenubarActive`, `AppIcon` renditions.
- `assetutil --info` on the compiled `Assets.car` confirms both menubar
  imagesets keep `"Template Mode" : "template"`.

**Out-of-scope confirmed untouched**: no files under `Sources/`, no
`project.pbxproj`, no `Contents.json` in the asset catalog, no
`LICENSES.md` (handoff is project-original CC0, same as before).
`docs/Stimmgabel-Icons-Designs/` kept in place as design provenance.
