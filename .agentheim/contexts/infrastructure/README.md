# infrastructure

## Purpose
Owns Stimmgabel's **globally-true tech concerns** — decisions and assets that apply across every BC, not specific to any single domain context. Initial scope:

- App bundle structure and entitlements
- Build / release tooling
- Code-signing & notarisation roadmap (deferred for v1 — see ADRs once they land)
- Distribution channel (later — GitHub release, Homebrew tap, …)
- Any future CI

BC-local tech concerns (the specific CoreAudio binding in `audio-engine`, the specific SwiftUI views in `menubar-ui`, the persistence mechanism that lives next to `menubar-ui`'s mute-state) stay inside their originating BC and do *not* belong here.

The **walking-skeleton spike** that proves the whole stack runs end-to-end lives in this BC's `todo/`, because it spans every BC and proves the *whole* stack runs.

## Classification
**generic**

Nothing domain-specific. If a future infra-flavoured decision turns out to be load-bearing for only one BC, route it to that BC's `todo/` instead.

## Actors
- **The author / future operators** — whoever builds, signs, and ships the app.
- **macOS itself** — Gatekeeper, the App Translocation service, the login-items registry, the codesign / notarytool tooling. Stimmgabel must coexist with these whether or not it is signed in v1.

## Ubiquitous language

Thin section — generic ops vocabulary. Recorded here so tasks and ADRs in this BC use it consistently.

- **App bundle** — the `.app` directory macOS treats as a single installable unit.
- **Entitlement** — a permission the app declares it needs (mic access, screen / system-audio capture, etc.). Encoded in the bundle.
- **Signature / notarisation** — the cryptographic chain that lets macOS Gatekeeper trust the app. Deferred for v1; relevant for v2+.
- **Login item** — the macOS facility that auto-launches an app at user login.
- **Release** — a built `.app` ready to be installed somewhere other than the build machine. v1: drag-installed locally. Later: distributed.

## Aggregates / Key events / Key commands
Not applicable — this BC holds tech decisions and shipping assets, not a domain.

## Relationships with other contexts
- **Upstream of audio-engine and menubar-ui.** Whatever bundle, entitlements, and build process this BC defines, the others run inside.
- See `context-map.md`.

## Open questions

### Walking skeleton (infrastructure-006) empirical answers

**Q1 — Ad-hoc-signed Audio Server Plugin loading (macOS 14.4+):**
Manual verification pending. The walking skeleton builds and the `.driver` bundle passes `codesign --verify --verbose` (ad-hoc signature: valid on disk, satisfies its Designated Requirement). Whether `coreaudiod` actually loads the ad-hoc-signed plug-in and exposes the device requires running `script/install-driver.sh` on a real Mac and checking Audio MIDI Setup. This is the next verification step.
*Expected answer: Yes — Background Music, BlackHole, and similar tools install ad-hoc-signed plugins successfully.*

**Q2 — App Sandbox compatibility with `AudioHardwareCreateProcessTap`:**
Not exercised in this spike. The walking skeleton app is **unsandboxed** (no `com.apple.security.app-sandbox` entitlement). The sandbox question applies only when the real Process Tap (ADR 0004) is wired in — that is a follow-up empirical task.

**Q3 — Install UX acceptability (single `sudo` prompt):**
Manual verification pending. The `script/install-driver.sh` is written to prompt exactly once. Subjective acceptability is for the author to judge after running the install on their Mac.

### Other open questions
- Whether the audio virtual device loads cleanly on macOS 26.x (Tahoe) given the project was built against the macOS 26.2 SDK but targets macOS 14.0+. The deployment target ensures binary compatibility; the SDK question is about runtime plugin loading behaviour on newer OS versions.
