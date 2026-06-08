# audio-engine — Index

Catalog of everything in this bounded context: tasks by status, ADRs scoped to this BC,
research touching this BC, and concept synthesis pages.

> Updated by: `model` (tasks), `work` (BC-scoped ADRs, concept page links), `research` (BC-scoped reports).

---

## Tasks by status

<!-- task-counts:start -->
- **Backlog:** 0
- **Todo:** 0
- **Doing:** 0
- **Done:** 6
<!-- task-counts:end -->

### Todo
<!-- todo-list:start -->
<!-- todo-list:end -->

### Doing
<!-- doing-list:start -->
<!-- doing-list:end -->

### Done (most recent first; older entries kept for prior-art search)
<!-- done-list:start -->
- **audio-engine-006** — Output adapter — XPC client that writes mix frames into the driver ring buffer and handles lazy activation — `done/audio-engine-006-output-adapter-ipc-client.md`
- **audio-engine-005** — Mix — combine mic side and system-audio side into a single float32 stereo buffer — `done/audio-engine-005-mix-both-sides.md`
- **audio-engine-004** — Mic capture — HAL IOProc on default input device, rebind on default-input change — `done/audio-engine-004-mic-capture-default-tracking.md`
- **audio-engine-003** — System-audio capture — Process Tap + aggregate device, rebind on default-output change — `done/audio-engine-003-system-audio-capture-process-tap.md`
- **audio-engine-002** — Decision — mute effect on upstream capture (v1 zero-in-mix; v1 architecture preserves v2 suspend-on-mute) — `done/audio-engine-002-mute-effect-on-upstream-capture.md`
- **audio-engine-001** — Decision — microphone capture & default-device tracking — `done/audio-engine-001-microphone-capture-and-default-device-tracking.md`
<!-- done-list:end -->

### Backlog
<!-- backlog-list:start -->
<!-- backlog-list:end -->

## ADRs scoped to this BC

<!-- adr-local:start -->
- **0010** — Mute behaviour for v1 — zero in the mix, with per-side adapter lifecycle preserved for v2 suspend-on-mute — 2026-06-05 — `knowledge/decisions/0010-mute-effect-on-upstream-capture.md`
- **0006** — Capture the mic side via CoreAudio HAL with property-listener-based default-device tracking — 2026-06-05 — `knowledge/decisions/0006-microphone-capture-and-default-device-tracking.md`
<!-- adr-local:end -->

## Research touching this BC

<!-- research-local:start -->
<!-- research-local:end -->

## Concepts (opt-in synthesis pages)

<!-- concepts:start -->
<!-- concepts:end -->

## Pointers

- BC README (ubiquitous language, invariants): `README.md`
