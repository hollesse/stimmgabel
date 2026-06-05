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
- Everything in the architect's foundation pass. ADR drafts arrive as `type: decision` task notes in this BC's `todo/`.
