---
id: 0003
title: Swift + SwiftUI MenuBarExtra with AppKit fallback; audio-engine is a UI-free Swift module
scope: global
status: accepted
date: 2026-06-05
supersedes: []
superseded_by: []
related_tasks: [infrastructure-001]
related_research: []
---

# ADR 0003: Swift + SwiftUI MenuBarExtra with AppKit fallback; audio-engine is a UI-free Swift module

## Context

Stimmgabel is a macOS menu-bar app that has to (a) interop intimately with C-shaped CoreAudio APIs and (b) present a tiny menu-bar dropdown with two toggles and a status line. The two halves have very different needs:

- The audio side wants direct, low-overhead access to CoreAudio HAL, Core Audio Taps, and Audio Server Plugin C contracts. Bridging through any non-Apple language layer adds cost without payoff.
- The UI side wants the lightest path to a menu-bar icon, a dropdown, and reactive state binding to audio-engine state — no preferences window, no custom controls, no design system (see ADR 0002).

A separate, load-bearing constraint from `audio-engine/README.md` and the testing ADR (this batch): the audio engine must be unit-testable in environments without a display server (CI). That requires zero UI imports from the engine module.

## Decision

- **Language: Swift 5.10 or later**, targeting the macOS minimum chosen by the system-audio-capture ADR (this batch).
- **UI framework: SwiftUI `MenuBarExtra` (macOS 13+) as the default**, with an AppKit `NSStatusItem` + `NSMenu` fallback used only for parts of the dropdown that `MenuBarExtra` cannot render correctly (custom icon state transitions, complex status-line layouts).
- **Module shape:** the codebase is structured as at least two Swift Package targets:
  - `AudioEngine` — pure Swift + CoreAudio interop. No SwiftUI, no AppKit, no UIKit imports. Public surface is a small command/event API.
  - `MenubarUI` — depends on `AudioEngine`. Owns all SwiftUI / AppKit code.
  An umbrella app target wires them together.
- **No Objective-C source files in v1.** Bridging headers are allowed where C APIs (CoreAudio, Audio Server Plugin SDK) need them, but no `.m` files written by us.

## Consequences

### Positive
- Native, idiomatic interop with every Apple audio API. No FFI layer.
- The audio-engine module is importable into XCTest without a display, enabling honest CI unit tests.
- `MenuBarExtra` gives us a one-screen dropdown for free; the AppKit fallback is a known, well-trodden escape hatch.
- Two-target Swift Package layout makes the BC boundary from ADR 0002 enforceable by the compiler — the audio-engine cannot accidentally import AppKit.

### Negative
- Swift's tooling for hot-reload of audio code is weak; iteration on real-time audio paths will involve full rebuilds.
- `MenuBarExtra` has known quirks (state retention on dropdown close, animation glitches with custom icons); we may have to fall back to AppKit earlier than hoped.
- Locking into Apple-only languages and frameworks means there is no realistic port path off macOS. This is consistent with the project's identity but worth naming.

### Neutral
- The Swift Package layout makes future BCs cheap to add as new targets.

## Alternatives considered

- **Pure AppKit (no SwiftUI).** Rejected. More boilerplate for zero gain on a two-toggle dropdown; SwiftUI's reactive bindings simplify the engine-to-UI projection.
- **Pure SwiftUI (no AppKit fallback declared up-front).** Rejected. `MenuBarExtra`'s edge cases are well-documented enough that pre-naming the fallback is honest planning, not over-engineering.
- **Objective-C / Objective-C++ for the audio core, Swift for the UI.** Rejected. Modern Swift handles CoreAudio interop fine via bridging headers; the extra language adds maintenance burden for a one-person v1.
- **Catalyst / cross-platform frameworks (Electron, Tauri, Flutter).** Rejected outright. None of them have viable low-latency CoreAudio Tap or Audio Server Plugin paths.

## References
- `vision.md` — Non-goals (no preferences window, no settings-rich app)
- `context-map.md` — partnership relationship between menubar-ui and audio-engine
- ADR 0002 — bounded contexts; the module split mirrors the BC split
