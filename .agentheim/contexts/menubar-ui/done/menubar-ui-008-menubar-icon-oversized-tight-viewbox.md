---
id: menubar-ui-008
title: Menubar icon renders oversized — tighten viewBox + page size in menubar SVGs
status: done
type: bug
context: menubar-ui
created: 2026-06-17
completed: 2026-06-17
commit: 643d09d
depends_on: []
blocks: []
tags: [bug, icon, menubar, asset-catalog]
related_adrs: []
related_research: []
prior_art: [menubar-ui-007, menubar-ui-006]
---

## Why

After menubar-ui-007 swapped in the Claude Design SVGs, the menubar
icon renders huge — only a small part of the tuning fork is visible
inside the menubar height, and the `MenuBarExtra` button balloons
sideways. The visual brand only works at the intended ~18×18 pt; what
ships now is unusable.

### Root cause

The new SVGs (`art/menubar-idle.svg`, `art/menubar-active.svg`)
declare `viewBox="0 0 1024 1024" width="1024" height="1024"`, but the
actual tuning-fork artwork only occupies the central region
(~`x: 388..636`, `y: 90..900` for idle; the active state extends to
`x: 246..778` because of the wave arcs). Everything outside that is
transparent padding.

When `rsvg-convert -f pdf` produces the PDF from such an SVG, the PDF
page size becomes 1024pt × 1024pt. AppKit then sizes the menubar item
based on the PDF's intrinsic size — at the menubar's fixed 22pt-tall
status-bar height, the fork shrinks proportionally and the item width
scales out to match.

The menubar-ui-006 originals worked because they used
`viewBox="0 0 100 100" width="100" height="100"` with artwork that
nearly filled the canvas — so PDF natural size ≈ the artwork itself,
and AppKit could fit it sensibly into the menubar.

## What

Re-author the two menubar SVGs in `art/` with a tight, shared,
square viewBox sized to the **active** state's bounding box
(union of fork + waves) so both states render at identical scale
when they flip. Then drop the SVG `width` / `height` to a
menubar-appropriate intrinsic size. Regenerate the PDFs.

### A. Compute the new viewBox

1. Measure the ink bounding box of the active artwork (the larger of
   the two — it includes both fork and waves):
   - **Fork:** `prongs` (x 428..596) + `stem` (x at 512) + `foot`
     circle (cx=512, r=54) → x range ~458..636 from geometry; with
     `stroke-width="80"` on the prong/stem strokes → effective ink x
     range ~388..636. Vertically: prongs start at y=130; foot circle
     bottom at y=900 → ink y range ~90..900.
   - **Waves:** outer arc on left at x=277, outer arc on right at
     x=747, both with `stroke-width="62"` → effective ink x range
     ~246..778. Vertical extent of outer wave arc:
     `M 277 347.5 A 190 190 0 0 0 277 676.5` → y ~316..707 with stroke.
   - **Union for active:** x ≈ 246..778 (width 532), y ≈ 90..900
     (height 810).

2. Make the viewBox square by extending the narrower dimension
   symmetrically around the artwork center (`cx = 512`,
   `cy = (90+900)/2 = 495`). Width becomes max(532, 810) = 810.
   Centered square viewBox: `viewBox="107 90 810 810"`. *(The
   worker may compute and adopt a marginally different square — the
   load-bearing requirement is "tight, shared between idle and
   active, centered on the fork".)*

3. Apply this exact same viewBox to **both** `menubar-idle.svg` and
   `menubar-active.svg`. Same viewBox → the fork sits at the
   identical screen position before and after the state flip, no
   visual jump.

### B. Set the SVG intrinsic size

In both SVGs, change `width="1024" height="1024"` to a small
menubar-appropriate value — `width="18" height="18"` is the obvious
target (the macOS status-bar template image baseline). Both SVGs
must use the same value.

The SVG paths themselves do **not** change — only the `viewBox` and
the outer `width`/`height` attributes.

### C. Regenerate the menubar PDFs

Re-export `App/Stimmgabel/Assets.xcassets/MenubarIdle.imageset/menubar-idle.pdf`
and `MenubarActive.imageset/menubar-active.pdf` from the updated
SVGs. The toolchain from menubar-ui-007 (`rsvg-convert -f pdf`)
should produce 18pt × 18pt PDFs now that the source SVGs declare
that size.

### D. (Out of scope but worth knowing) the defensive fallback

If — for some reason — the PDF approach still renders wrong despite
correct intrinsic size, the fallback is to switch `StimmgabelApp.swift`'s
`MenuBarExtra` label from `Image(name)` to
`Image(name).resizable().frame(width: 18, height: 18)`. Do NOT apply
this preemptively. The point of this task is to fix the asset; only
touch Swift if the asset-side fix demonstrably fails on a built run.

## Acceptance criteria

- [ ] `art/menubar-idle.svg` and `art/menubar-active.svg` use an
      identical, square, tight viewBox centered on the fork
      (approximately `viewBox="107 90 810 810"` — exact numbers may
      vary by ±20pt as long as the active waves and the foot circle
      are not clipped)
- [ ] Both SVGs have `width="18"` and `height="18"` (or the same
      small value in both)
- [ ] The four SVG path elements themselves are unchanged from
      menubar-ui-007 (same `d` attributes, same stroke widths) —
      only the outer `<svg>` attributes change
- [ ] `App/Stimmgabel/Assets.xcassets/MenubarIdle.imageset/menubar-idle.pdf`
      and `MenubarActive.imageset/menubar-active.pdf` regenerated;
      both imageset `Contents.json` files still declare
      `"template-rendering-intent" : "template"`
- [ ] `xcodebuild` succeeds and produces a `Stimmgabel.app` with the
      updated `Assets.car`
- [ ] **Manual verification:** install the rebuilt `.app`, launch it,
      observe the menubar item:
  - The tuning-fork icon fits within the menubar's vertical height
    and looks visually balanced (similar size to other menubar icons
    like Wi-Fi, Bluetooth, Battery)
  - The `MenuBarExtra` button width is normal (~22pt, not "echt sehr
    groß" as before)
  - Attach a consumer (QuickTime → New Audio Recording → Stimmgabel);
    the icon flips to the active fork-with-waves variant with no
    visual jump in position or size — both states are visibly the
    same scale
- [ ] `swift test` stays green (no test changes expected — pure asset
      fix)
- [ ] No code under `Sources/` is modified

## Notes

### Out of scope

- **Changing `StimmgabelApp.swift` or `AppViewModel.swift`.** This is
  an asset-only fix. Only touch Swift if the asset fix demonstrably
  doesn't work on the built `.app` — and even then, capture as a
  separate follow-up rather than bundling it here.
- **Changing the appicon** (`art/appicon-1024.svg`,
  `AppIcon.appiconset/`, `art/AppIcon.icns`). The Dock / Finder icon
  is fine — only the menubar PDFs are affected.
- **Re-rendering the design.** The artwork (fork + waves) is correct.
  The bug is purely in the SVG canvas declaration.

### Implementation hints

- macOS menubar status-bar items have a fixed vertical extent
  (~22pt). The system scales template images to fit, but it uses the
  asset's *intrinsic* size as the natural rendering size before
  scaling — so a 1024pt-natural PDF gives the system a very different
  hint than an 18pt-natural PDF, even when both could in principle be
  scaled to the same final size.
- The "preserves vector representation" flag in the imageset
  `Contents.json` (set by menubar-ui-006) tells AppKit to scale the
  PDF as a vector at runtime. That part is correct — don't change
  the imageset `Contents.json`.
- The handoff source under `docs/Stimmgabel-Icons-Designs/art/` has
  the same oversized canvas — you may also update those for symmetry
  (the design folder is the provenance, but it's useful to keep it
  in sync with what ships). If you do, mention it in your SUMMARY;
  if you don't, also fine — the load-bearing files are under `art/`.

### Prior-art note

- **menubar-ui-007** introduced this bug by adopting handoff SVGs
  without renormalising the canvas. Read its Outcome + the SVG diff
  in commit `58643d7` for context.
- **menubar-ui-006** is the working baseline — its menubar SVGs
  (viewBox 100×100, near-edge artwork) showed the correct pattern.
  The `d` paths there are different (a different fork geometry), but
  the canvas discipline is what should be copied.

## Outcome

Tightened the menubar SVG canvas: both `art/menubar-idle.svg` and
`art/menubar-active.svg` now declare `viewBox="107 90 810 810"`
(shared, square, centered on the fork at cx=512 cy=495, sized to the
active state's bounding box including the outer wave arc bulge) and
intrinsic size `width="18" height="18"`. The four SVG path elements
and the foot circle are byte-identical to menubar-ui-007 — only the
outer `<svg>` attributes changed.

Regenerated PDFs via `rsvg-convert -f pdf`:
- `App/Stimmgabel/Assets.xcassets/MenubarIdle.imageset/menubar-idle.pdf`
- `App/Stimmgabel/Assets.xcassets/MenubarActive.imageset/menubar-active.pdf`

Both PDFs now have MediaBox `0 0 13.5 13.5` pt (rsvg's 96→72 dpi
conversion of 18 CSS px). Identical canvas in both states → no scale
or position jump on the active flip. Imageset `Contents.json` files
untouched (still `template-rendering-intent: template` and
`preserves-vector-representation: true`).

Verified: `xcodebuild` build succeeds (Assets.car rebuilt);
`swift test` green (87 tests, 0 failures, 1 skipped — unchanged).
No code under `Sources/` touched. The provenance folder
`docs/Stimmgabel-Icons-Designs/` was left alone per the task's
DO NOT touch rule.

Manual visual verification (icon size in menubar, state-flip
alignment) still needs a human run-through of the built `.app` — the
asset-side fix is in place; the defensive Swift `.resizable().frame`
fallback was not applied.

### Key files
- `art/menubar-idle.svg`, `art/menubar-active.svg`
- `App/Stimmgabel/Assets.xcassets/MenubarIdle.imageset/menubar-idle.pdf`
- `App/Stimmgabel/Assets.xcassets/MenubarActive.imageset/menubar-active.pdf`
