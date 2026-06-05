---
id: infrastructure-004
title: Decision — build & release tooling
status: done
type: decision
context: infrastructure
created: 2026-06-05
completed: 2026-06-05
commit: 060286b
depends_on: [infrastructure-001]
blocks: []
tags: [foundation, build, release, spm, xcode]
related_adrs: [0008]
related_research: [macos-audio-platform-2026-06-05]
prior_art: []
---

## Why
The build approach has to produce a runnable `.app` plus an Audio Server Plugin (`.driver`), and grow into a fully-signed/notarised v2 distribution without a tooling rewrite. It also has to enforce the BC module boundary from ADR 0002 at the compiler level.

This task depends on `infrastructure-001` (language & UI framework) because the SPM layout follows the language decision.

## What
Commit ADR 0008 capturing: **`Package.swift` at the repo root defining `AudioEngine` + `MenubarUI` SPM products, plus an `App/Stimmgabel.xcodeproj`** containing the app target and the Audio Server Plugin target. CLI entry point: `xcodebuild`.

**v1 produces ad-hoc-signed artifacts** (both the `.app` and the `Stimmgabel.driver` bundle) — the build runs `codesign --sign -` so the plug-in is loadable by `coreaudiod` on current macOS. v2's increment is configuration only: swap the ad-hoc identity for a Developer ID, add a `notarytool submit` step. No tooling change required.

**Research findings (`macos-audio-platform-2026-06-05`) changed one thing in the architect's original draft:** the original "v1 is unsigned, period" plan does not work — Audio Server Plugins require at minimum an ad-hoc signature on current macOS. Ad-hoc signing has been folded into v1's build. Full Developer ID + notarisation stays v2's concern.

## Acceptance criteria
- [ ] `knowledge/decisions/0008-build-and-release-tooling.md` exists with `scope: global`, `status: accepted`.
- [ ] The chosen layout makes ADR 0002's BC boundary compiler-enforced.
- [ ] `knowledge/index.md` updated under `<!-- adr-global:start -->`.
- [ ] No code changes (the walking-skeleton spike, `infrastructure-006`, materialises the actual project).

## Outcome

ADR 0008 written at `.agentheim/knowledge/decisions/0008-build-and-release-tooling.md`. Captures the SPM + thin Xcode project layout (scope: global, status: accepted). The two-module SPM split (`AudioEngine`, `MenubarUI`) enforces the ADR 0002 BC boundary at the compiler level. v1 uses ad-hoc signing for both `.app` and `.driver`; v2 path reserved as configuration-only change.

## Notes

Architect draft, **amended on 2026-06-05 to reflect research findings** (ad-hoc signing is required in v1, not deferred to v2). Paste into the ADR with id `0008`, status `accepted`, date `2026-06-05`:

```markdown
---
id: 0008
title: Build with SPM modules + a minimal Xcode app target driven by xcodebuild; ad-hoc sign in v1, Developer-ID + notarise in v2
scope: global
status: accepted
date: 2026-06-05
supersedes: []
superseded_by: []
related_tasks: [infrastructure-004]
related_research: [macos-audio-platform-2026-06-05]
---

# ADR 0008: Build with SPM modules + a minimal Xcode app target driven by xcodebuild; ad-hoc sign in v1, Developer-ID + notarise in v2

## Context

`vision.md` defers full code-signing and notarisation to v2 — for v1 the author runs locally-built artefacts, drag-installed. Research (`macos-audio-platform-2026-06-05`) found, however, that the Audio Server Plugin published per ADR 0005 needs **at minimum an ad-hoc signature** to load on current macOS; truly unsigned plug-ins are unreliable. So v1 sits at "ad-hoc signed", not "unsigned". The build tooling needs to be the lightest thing that:

- Produces a runnable `.app` and a loadable, ad-hoc-signed `Stimmgabel.driver` plug-in on the author's Mac today.
- Can grow into a Developer-ID-signed + notarised build for v2 without a tooling rewrite — only configuration changes.
- Lets the Audio Server Plugin (a separate target with its own bundle layout, see ADR 0005) be built and embedded into the app bundle.
- Keeps the BC module boundary from ADR 0002 enforced at the compiler level.

Options:

- **Pure SPM (`swift build`).** Cannot produce an `.app` bundle, cannot build an Audio Server Plugin (`.driver` bundle). Hard non-starter for a macOS app with a custom bundle and an audio plug-in.
- **Pure Xcode project.** Works, but Xcode projects are merge-hostile XML, and the BC module boundary ends up enforced by Xcode target membership rather than by `Package.swift`'s explicit dependency graph.
- **SPM + thin Xcode app target.** SPM packages define the `AudioEngine` and `MenubarUI` modules with explicit dependencies; the Xcode project is a one-trick app target plus a `.driver` plug-in target, both pulling code from the SPM packages.
- **Tuist / XcodeGen.** Generate the Xcode project from a higher-level description. Useful when you have many targets; pure overhead for two modules + one app + one plug-in.

## Decision

- **Repository root contains a `Package.swift`** declaring two SPM library products:
  - `AudioEngine` — pure Swift, depends only on system frameworks (CoreAudio, CoreFoundation, AudioToolbox).
  - `MenubarUI` — depends on `AudioEngine`, SwiftUI, AppKit.
- **`App/Stimmgabel.xcodeproj`** contains two targets:
  - `Stimmgabel` (the menu-bar app) — links the SPM products, embeds the `.driver` plug-in into `Contents/Resources/`.
  - `StimmgabelDriver` (the Audio Server Plugin) — its own bundle target, written against the Audio Server Plugin SDK in Objective-C / C with the necessary bridging.
- **CLI entry point: `xcodebuild`.** A short `script/build` shell wrapper invokes `xcodebuild -project App/Stimmgabel.xcodeproj -scheme Stimmgabel -configuration Release` and copies the result to `dist/Stimmgabel.app`.
- **v1 ad-hoc signs the artefacts.** Both targets (`Stimmgabel.app` and `Stimmgabel.driver`) build with `CODE_SIGN_IDENTITY=-` (the ad-hoc identity). The build script verifies both bundles have a signature via `codesign --verify --verbose` before copying to `dist/`. This is the minimum macOS will load for an Audio Server Plugin; it is not enough for a clean Gatekeeper / Notarisation experience but it is enough for the author's local Mac.
- **Optional `xattr -dr com.apple.quarantine` step** in `script/install-driver.sh` (ADR 0005) to remove the quarantine attribute if the `.app` was downloaded rather than built locally.
- **v2 / Developer-ID + notarised path is reserved but not implemented:** the same `xcodebuild` invocation can later accept `CODE_SIGN_IDENTITY="Developer ID Application: ..."`, `DEVELOPMENT_TEAM=...`, and the build script can append a `notarytool submit ... --wait` step. No tooling change required, only configuration. Note: the `.driver` bundle has its own code-signing requirements distinct from the `.app`; v2 must sign both (Apple Developer Forums thread/676781 — Quinn at DTS on dev vs distribution signing for Audio Server Plugins).

## Consequences

### Positive
- Two-module SPM split makes the BC boundary compiler-enforced: `AudioEngine` cannot accidentally import AppKit because its package manifest doesn't list it.
- The Xcode project is small enough (one app + one plug-in target) that its XML rarely changes; merge conflicts are unlikely.
- `xcodebuild` is the lingua franca of macOS CI — a future CI run on GitHub Actions' `macos-latest` runner uses the same invocation as the local build.
- The v2 sign / notarise path is a configuration delta, not a tooling migration.

### Negative
- An Xcode project still has to be committed to the repository. SPM-only would be cleaner, but cannot ship a `.app` plus a `.driver` plug-in.
- New contributors need Xcode installed (not just the command-line tools) to open and edit the project.

### Neutral
- The author already has Xcode; this is not a meaningful onboarding cost for v1.

## Alternatives considered

- **Tuist.** Rejected for v1. Worth revisiting if the project grows beyond ~5 targets.
- **XcodeGen.** Rejected for v1. Same rationale.
- **Pure SPM.** Rejected — cannot produce an `.app` or an Audio Server Plugin bundle.
- **Pure Xcode (no SPM packages).** Rejected — loses the compiler-enforced BC module boundary.

## References
- `vision.md` — Non-goals (updated): not fully Developer-ID-signed and notarised in v1, but ad-hoc-signed
- `infrastructure/README.md` — purpose includes build/release tooling and code-signing roadmap
- `knowledge/research/macos-audio-platform-2026-06-05.md` — claims 3.3 and 3.5, ad-hoc-signing requirement
- ADR 0002 — bounded contexts (the SPM split mirrors the BC split)
- ADR 0005 — Audio Server Plugin install (`script/install-driver.sh` depends on this build's `dist/` output)
- Apple Developer Forums thread/676781 — Quinn (DTS) on dev vs distribution signing for Audio Server Plugins
```
