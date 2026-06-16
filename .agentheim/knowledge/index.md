# Index

Top-level catalog of this project's bounded contexts, global decisions, and research.
For BC-scoped artifacts, see each BC's `INDEX.md`.

> Updated by: `model` (BC creation), `work` (global ADRs), `research` (reports tagged global / cross-BC), backfill script.
> Hand-edits are fine but the skills will append at the section markers below.

---

## Bounded contexts

<!-- bc-list:start -->
- **audio-engine** — capture mic + system audio, mix, publish a virtual mic; track default-device changes; lazy activation — `contexts/audio-engine/INDEX.md`
- **menubar-ui** — menu-bar icon + dropdown with mute toggles and status; the only user-visible surface — `contexts/menubar-ui/INDEX.md`
- **infrastructure** — globally-true tech concerns: bundle, entitlements, build, code-signing roadmap; home of the walking-skeleton spike — `contexts/infrastructure/INDEX.md`
<!-- bc-list:end -->

## Global ADRs (scope: global)

<!-- adr-global:start -->
- **0013** — v1 signing path is Apple Development cert (Keychain locally, GitHub Secret in CI), not true ad-hoc — clarifies ADR 0008's v1 row — 2026-06-16 — `knowledge/decisions/0013-v1-signing-apple-development-cert-via-ci-secret.md`
- **0012** — Driver IPC on macOS 26 — POSIX SHM (audio frames) + Darwin notify (consumer-active) — supersedes XPC Mach service approach — 2026-06-05 — `knowledge/decisions/0012-driver-ipc-macos26-shm-notifications.md`
- **0009** — Three-tier testing: XCTest units on CI, live-audio integration on real Mac, manual smoke checklist — 2026-06-05 — `knowledge/decisions/0009-testing-strategy.md`
- **0008** — SPM modules + thin Xcode app target; ad-hoc sign v1, Developer ID + notarise v2 — 2026-06-05 — `knowledge/decisions/0008-build-and-release-tooling.md`
- **0005** — Audio Server Plugin for virtual mic publishing; system-domain install with ad-hoc signing — 2026-06-05 — `knowledge/decisions/0005-virtual-mic-publishing-mechanism.md`
- **0004** — CoreAudio Process Tap API for system-audio capture; minimum macOS 14.4 (Sonoma) — 2026-06-05 — `knowledge/decisions/0004-system-audio-capture-mechanism.md`
- **0003** — Swift + SwiftUI MenuBarExtra with AppKit fallback; audio-engine is a UI-free Swift module — 2026-06-05 — `knowledge/decisions/0003-language-and-ui-framework.md`
- **0002** — Bounded contexts: audio-engine, menubar-ui, infrastructure (no design-system BC for v1) — 2026-06-05 — `knowledge/decisions/0002-bounded-contexts.md`
- **0001** — Stimmgabel is a single-user, local-only macOS tool (no server, no sync) — 2026-06-05 — `knowledge/decisions/0001-single-user-local.md`
<!-- adr-global:end -->

## Cross-BC research

Research reports relevant to more than one BC (or to the project as a whole). BC-specific
reports are listed in each BC's `INDEX.md`.

<!-- research-global:start -->
- **macos-audio-platform-2026-06-05** — verification of Stimmgabel foundation claims (Process Tap, ScreenCaptureKit, Audio Server Plugin, etc.) — 2026-06-05 — `knowledge/research/macos-audio-platform-2026-06-05.md`
<!-- research-global:end -->

## Pointers

- Vision: `vision.md`
- Context map: `context-map.md`
- Protocol (chronological log): `knowledge/protocol.md` — newest entries on top
- All ADRs: `knowledge/decisions/`
- All research: `knowledge/research/`
