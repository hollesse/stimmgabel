---
id: menubar-ui-001
title: Decision — mute-state persistence
status: done
type: decision
context: menubar-ui
created: 2026-06-05
completed: 2026-06-05
commit: 41a2fd2
depends_on: []
blocks: []
tags: [foundation, persistence, userdefaults]
related_adrs: [0007]
related_research: []
prior_art: []
---

## Why
The vision lists mute persistence as an assumed-yes open question. Resolving it BC-locally now (only `menubar-ui` cares about user-visible state surviving restarts) keeps the decision in the right place and gives the worker a clear contract.

## What
Commit ADR 0007 capturing the architect's recommendation: persist the two mute booleans in `UserDefaults.standard` behind a thin `MutePreferences` value type. BC-local to `menubar-ui`.

## Acceptance criteria
- [ ] `knowledge/decisions/0007-mute-state-persistence.md` exists with `scope: menubar-ui`, `status: accepted`.
- [ ] `contexts/menubar-ui/INDEX.md` updated under `<!-- adr-local:start -->`.
- [ ] No code changes.

## Outcome

ADR 0007 written at `.agentheim/knowledge/decisions/0007-mute-state-persistence.md` with `scope: menubar-ui`, `status: accepted`. Resolves the open question in the menubar-ui README: mute booleans persisted via `UserDefaults.standard` behind a `MutePreferences` value type. INDEX.md not updated — orchestrator owns index writes per protocol.

## Notes

Architect draft (paste into the ADR with id `0007`, status `accepted`, date `2026-06-05`):

```markdown
---
id: 0007
title: Persist per-side mute state in UserDefaults (BC-local to menubar-ui)
scope: menubar-ui
status: accepted
date: 2026-06-05
supersedes: []
superseded_by: []
related_tasks: [menubar-ui-001]
related_research: []
---

# ADR 0007: Persist per-side mute state in UserDefaults (BC-local to menubar-ui)

## Context

`vision.md` lists mute persistence as an open question with an assumed-yes answer ("set-and-forget"). The `menubar-ui/README.md` open questions echo this. Only `menubar-ui` cares about user-visible state surviving restarts — the audio-engine does not care whether a side started muted or not, it just receives `SetSideMute` commands. This makes the decision BC-local: if the menubar-ui BC didn't exist, this question wouldn't either.

The thing to persist is exactly two booleans: `micSideMuted`, `systemAudioSideMuted`. Read once at app launch (so the engine starts in the right mute state). Written on every toggle.

Storage options on macOS:

- **`UserDefaults`** (standard plist, app-domain).
- **A small JSON / plist file in `~/Library/Application Support/Stimmgabel/`**.
- **Keychain.** Wrong shape — these are not secrets.
- **An embedded database (SQLite / SwiftData / Core Data).** Comically over-engineered for two booleans.

## Decision

Use **`UserDefaults.standard`** with two keys (suggested: `com.innoq.stimmgabel.muteMicSide`, `com.innoq.stimmgabel.muteSystemAudioSide`). The reads and writes are wrapped in a small `MutePreferences` value type inside the `menubar-ui` BC, so the storage detail does not leak into view code or into the `AppShell` aggregate's projection.

The audio-engine BC is not affected by this decision. On app launch, `menubar-ui` reads the persisted values and issues the corresponding `SetSideMute` commands to the engine before any consumer can attach.

## Consequences

### Positive
- Trivial code. `UserDefaults` is sandbox-safe, atomic enough for our purposes, automatically backed up by macOS as part of app preferences.
- No filesystem layout to design, no schema to maintain.
- The wrapping `MutePreferences` value type makes the storage swappable later without churning the views — useful if Stimmgabel ever grows actual preferences (which the vision currently rules out).

### Negative
- `UserDefaults` is not the right place if Stimmgabel ever needs to grow profiles, per-app configurations, or anything bigger than a handful of scalar values. We accept this; when that day comes, the wrapping value type contains the blast radius of changing storage.
- `UserDefaults` writes are coalesced; on a hard kernel-panic crash within a few seconds of a toggle, the mute state may not be flushed. Acceptable for a non-critical UX preference.

### Neutral
- BC-local: nothing in this ADR is visible from `audio-engine` or `infrastructure`.

## Alternatives considered

- **JSON / plist file in Application Support.** Rejected. Same outcome, more code. `UserDefaults` is the Apple-blessed home for exactly this.
- **SwiftData / Core Data.** Rejected as over-engineering.
- **iCloud-synced `NSUbiquitousKeyValueStore`.** Rejected. ADR 0001 locks Stimmgabel as single-user / local-only / no cloud sync.

## References
- `vision.md` — Open questions: "Mute persistence across app restart / reboot — assumed yes; revisit if surprising in practice"
- `menubar-ui/README.md` — Open questions: "Mute-state persistence across app restart / reboot — assumed yes; storage mechanism TBD by architect"
- ADR 0001 — single-user, local-only
- ADR 0002 — bounded contexts (BC-local infrastructure stays inside the originating BC)
```
