---
id: 0001
title: Stimmgabel is a single-user, local-only macOS tool
scope: global
status: accepted
date: 2026-06-05
supersedes: []
superseded_by: []
related_tasks: []
related_research: []
---

# ADR 0001: Stimmgabel is a single-user, local-only macOS tool

## Context

Stimmgabel's purpose is to merge the macOS default microphone with all system audio into a single virtual input device for downstream consumer apps (transcription, recording, screen capture). The author's day-to-day use case is solo. A foreseeable secondary use case is an INNOQ ensemble-programming team where every member installs Stimmgabel independently, so a rotating "AI driver" always has the same routing tool available.

Even in the team scenario, the audio routing is per-Mac. No two instances of Stimmgabel ever need to communicate. There is no shared state, no cross-machine session, no account model, no upstream service the app depends on.

## Decision

Stimmgabel is built as a single-user, local-only macOS app. No server component. No cloud sync. No account model. No cross-device feature. Every install is fully self-contained.

## Consequences

### Positive
- No backend to design, deploy, or maintain.
- No privacy surface beyond what runs on the user's own Mac.
- No authentication or authorisation work.
- The team use-case (multiple installs across teammates) is supported "for free" by individual installs — nothing extra to build.
- Reasoning stays focused: every concern is local; there is no distributed-systems thinking to do.

### Negative
- Future features that would benefit from sync (e.g. "remember my mute preferences across all my Macs") are out of scope by design.
- Telemetry / crash reporting, if ever desired, would need to be added against this baseline.

### Neutral
- The team-use scenario still requires per-user installation. There is no central "deploy to team" mechanism; this is acceptable because the audience is small and technical.

## Alternatives considered

- **Add a sync component for shared mute / device profiles** — rejected. The product value lives in zero-config single-Mac routing; sync would add an account model and a service to an app whose appeal is its minimalism.
- **Build a small companion service for telemetry / updates** — rejected for v1. Auto-update can be revisited when v2 ships beyond the author; manual updates are fine in the meantime.

## References

- `vision.md` — Users / Non-goals sections
- `context-map.md`
