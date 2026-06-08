---
id: menubar-ui-002
title: Mute toggles — wire mic-side and system-audio-side mute to AudioPipeline, persist via UserDefaults
status: done
type: feature
context: menubar-ui
created: 2026-06-05
completed: 2026-06-05
commit: fcfadaa
depends_on: [audio-engine-006]
blocks: []
tags: [mute, toggle, userdefaults, persistence, swiftui, menubar]
related_adrs: [0007, 0003, 0009]
related_research: []
prior_art: [menubar-ui-001]
---

## Why

The user needs a single binary toggle per side to drop that side from the mix. ADR 0007 decided
persistence: `UserDefaults.standard` behind a `MutePreferences` value type, so mute state survives
app restart and reboot. The menu-bar UI is the only control surface.

## What

Wire the Stimmgabel dropdown so the two mute toggles:

1. **Read from and write to `MutePreferences`** — a lightweight value type backed by
   `UserDefaults.standard` with two `Bool` keys (`micMuted`, `systemAudioMuted`). On app launch,
   `AudioPipeline` is initialised with the persisted values.

2. **Call `AudioPipeline.setMicMuted(_:)` and `AudioPipeline.setSystemAudioMuted(_:)`** when the
   user toggles an item. The pipeline applies the mute immediately (next render cycle, per ADR 0010).

3. **Show checkmarks** reflecting current mute state — if `micMuted == true`, the "Mic" menu item
   shows a checkmark. Same for "System audio".

4. **Dropown items** (minimal v1 layout):
   - ✓ Mic (checkmark when muted)
   - ✓ System audio (checkmark when muted)
   - ─ (separator)
   - Quit

5. **Icon state** — the menu-bar icon changes to reflect mute state:
   - Idle (no consumer): a distinct idle symbol.
   - Active, no mute: normal active symbol.
   - Active, one side muted: a muted-variant symbol.
   - Exact symbols (SF Symbol names or emoji) are the implementer's choice; keep it recognisable.

## Acceptance criteria

- [ ] Toggling "Mic" in the dropdown silences the mic side in the next render cycle; unchecking
      restores it. Verified manually (Tier-3 smoke test) or via a Tier-2 integration test.
- [ ] Toggling "System audio" silences that side; unchecking restores it.
- [ ] Mute state is written to `UserDefaults` immediately on toggle.
- [ ] After quitting and relaunching the app, the previous mute state is restored — both the
      `AudioPipeline` internal state and the checkmark in the dropdown.
- [ ] The menu-bar icon updates within one runloop cycle of a mute change.
- [ ] The Tier-1 unit test for `MutePreferences` round-trips `micMuted` and `systemAudioMuted`
      through a test `UserDefaults` suite (not `.standard`) and verifies correct read-back.
- [ ] Existing Tier-1 tests continue to pass.

## Notes

- ADR 0007 specifies `MutePreferences` as the value type. Its interface:
  ```swift
  struct MutePreferences {
      var micMuted: Bool
      var systemAudioMuted: Bool
      // read from / write to UserDefaults.standard
  }
  ```
- No `design-system` gate — the menubar-ui BC's README explicitly states there is no styleguide
  requirement for v1 (the only surface is standard macOS AppKit/SwiftUI menu controls).
- The "Quit" item should call `NSApplication.shared.terminate(nil)`. Quitting while a consumer is
  reading is fine — the driver emits silence; the consumer may log an error, which is acceptable.
- ADR 0003 decided SwiftUI `MenuBarExtra` with AppKit fallback. The implementer should use
  `MenuBarExtra` if targeting macOS 13+ (which the deployment target supports); AppKit fallback
  is only if `MenuBarExtra` proves too constrained for the toggle + icon-state requirements.

## Outcome

Implemented full mute-toggle + persistence stack for the menubar-ui BC:

- `Sources/MenubarUI/MutePreferences.swift` — value type with `micMuted`/`systemAudioMuted` backed by `UserDefaults`. Keys per ADR 0007.
- `Sources/MenubarUI/AppViewModel.swift` — `@MainActor ObservableObject` owning pipeline + output adapter. Restores persisted mute on init, propagates toggles to pipeline and `UserDefaults`. Computes dynamic SF Symbol icon name.
- `Sources/MenubarUI/MenuBarView.swift` — two checkable menu items (Mic / System audio), separator, Quit.
- `Sources/MenubarUI/StimmgabelApp.swift` — `MenuBarExtra` wired to view model; icon follows `menuBarIconName`.
- `Tests/MenubarUITests/MutePreferencesTests.swift` — 7 Tier-1 round-trip tests (isolated `UserDefaults` suite, never `.standard`).
- `Tests/MenubarUITests/AppViewModelTests.swift` — 12 Tier-1 tests verifying icon projection, mute propagation to pipeline, and persistence-on-toggle.
- `Package.swift` — `MenubarUITests` test target added.
- `App/Stimmgabel.xcodeproj/project.pbxproj` — `MenubarUITests` Xcode target added.
- `App/Stimmgabel.xcodeproj/xcshareddata/xcschemes/MenubarUITests.xcscheme` — test scheme added.

All 60 tests pass (19 new, 41 pre-existing).
