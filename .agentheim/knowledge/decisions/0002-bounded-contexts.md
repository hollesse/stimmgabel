---
id: 0002
title: Bounded contexts — audio-engine, menubar-ui, infrastructure (no design-system BC for v1)
scope: global
status: accepted
date: 2026-06-05
supersedes: []
superseded_by: []
related_tasks: []
related_research: []
---

# ADR 0002: Bounded contexts — audio-engine, menubar-ui, infrastructure (no design-system BC for v1)

## Context

Stimmgabel is small (a single macOS app process), but the brainstorm conversation surfaced two distinct concerns with materially different vocabularies:

- **audio-engine** thinks in samples, frames, buffers, sample rates, channels, `AudioDeviceID`s, CoreAudio callbacks, and the rules around lazy activation and default-device tracking. It is conformist to macOS audio frameworks.
- **menubar-ui** thinks in menu items, dropdowns, toggles, icon states, login items, and user-visible state projection. It is a thin layer over AppKit/SwiftUI.

A third concern — app bundle structure, entitlements, build/release tooling, and the deferred code-signing roadmap — is generic and globally-true across both, and needs a permanent home so it doesn't fragment into ad-hoc directories as the project grows.

A separate question was whether to spin up a `design-system` BC. Stimmgabel's user-facing surface is a menu-bar icon and a dropdown using stock AppKit/SwiftUI controls. No custom components, no visual tokens, no shared patterns to maintain.

## Decision

Three bounded contexts for v1:

1. **audio-engine** — core. The mix and the virtual mic.
2. **menubar-ui** — supporting. The user-facing surface.
3. **infrastructure** — generic. Globally-true tech concerns and the walking-skeleton spike.

**No `design-system` BC.** Frontend tasks in `menubar-ui` (and any other future frontend-bearing BC) do *not* depend on a styleguide task. If Stimmgabel later grows a settings window, onboarding screens, or any visually-meaningful surface, revisit and add the BC then.

BC-local infrastructure (specific CoreAudio binding, specific SwiftUI views, the persistence mechanism for mute state) stays inside the originating BC and is *not* hoisted into `infrastructure/`.

## Consequences

### Positive
- Clear separation of concerns: workers and refiners always know which BC owns a given thought (audio plumbing → audio-engine; user-visible state → menubar-ui; build/sign/ship → infrastructure).
- Ubiquitous language stays coherent inside each BC instead of collapsing into one mixed vocabulary.
- Tech-foundation ADRs have a permanent home (`infrastructure/`) and don't fragment into per-BC duplicates.
- Skipping `design-system` avoids ceremony for a menu-bar app whose entire UI is two checkboxes and an icon.

### Negative
- Three READMEs and three INDEXes for what is, today, a small codebase. Mild discoverability overhead.
- The `menubar-ui` ↔ `audio-engine` partnership requires explicit interface discipline even though they ship together in the same process. Without it the split adds friction without payoff.

### Neutral
- The split is for cognitive clarity, not deployment independence. Both domain BCs build into the same `.app` bundle.

## Alternatives considered

- **One BC ("app")** — rejected. The vocabularies are too different; the project benefits from having "samples and devices" and "menu items and toggles" be distinct concerns.
- **Add a `design-system` BC anyway** — rejected for v1. No design language to maintain. The cost (extra BC, extra styleguide-gate dependency on every frontend task) outweighs the benefit at this scale. Revisit if the UI grows.
- **Fold infrastructure into one of the domain BCs** — rejected. Tech-foundation decisions are globally true; embedding them in a domain BC misroutes future captures.

## References

- `vision.md`
- `context-map.md`
