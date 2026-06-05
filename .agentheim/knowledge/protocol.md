# Protocol

Chronological log of everything that happens in this project.
Newest entries on top.

---

## 2026-06-05 12:00 -- Work session resumed: [infrastructure-001, menubar-ui-001]

**Type:** Work / Batch start (resumed)
**Tasks:** infrastructure-001 - Decision — language & UI framework, menubar-ui-001 - Decision — mute-state persistence
**Parallel:** yes (2 workers)

---

## 2026-06-05 11:55 -- Task completed (verification skipped): audio-engine-001 - Decision — microphone capture & default-device tracking

**Type:** Work / Task completion
**Task:** audio-engine-001 - Decision — microphone capture & default-device tracking
**Summary:** ADR 0006 written: capture mic side via CoreAudio HAL with AudioObjectAddPropertyListener for default-device tracking. BC-local to audio-engine.
**Verification:** SKIPPED — decision-only task (type: decision, FILES_CHANGED == 1, single ADR file)
**Commit:** (pending — session was interrupted; committed in this recovery)
**Files changed:** 1
**ADRs written:** 0006-microphone-capture-and-default-device-tracking.md

---

## 2026-06-05 10:40 -- Batch started: [audio-engine-001, menubar-ui-001, infrastructure-001]

**Type:** Work / Batch start
**Tasks:** audio-engine-001 - Decision — microphone capture & default-device tracking, menubar-ui-001 - Decision — mute-state persistence, infrastructure-001 - Decision — language & UI framework
**Parallel:** yes (3 workers)

---

## 2026-06-05 — Research + foundation amendments (post-brainstorm review)

**Type:** Research + ADR amendments
**Trigger:** user reviewed brainstorm output, asked for (a) empirical verification of the architect's platform claims and (b) a separate ADR on mute behaviour with explicit v2 optionality.
**Outcome:** one research report + one new decision task + amendments to three existing foundation decision tasks and the walking skeleton.

**Research:** `knowledge/research/macos-audio-platform-2026-06-05.md` — verified architect's claims about CoreAudio Process Tap, ScreenCaptureKit, Audio Server Plugin, DriverKit, MenuBarExtra, and Mach-service IPC. Material corrections found in three claims (see "Amendments" below). Two empirical questions surfaced that documentation cannot answer; both rolled into the walking skeleton's acceptance criteria.

**New decision task:** `contexts/audio-engine/todo/audio-engine-002-mute-effect-on-upstream-capture.md` — drafts ADR 0010 (`scope: audio-engine`, BC-local). v1 ships "zero in the mix"; v1 architecture explicitly preserves a per-side `UpstreamCaptureAdapter` protocol with independent `start()` / `stop()` so v2's "suspend capture on mute" is a localised code change (≈ half-day estimate). Closes the audio-engine README's mute open question.

**Amendments to foundation tasks (driven by research):**
- `infrastructure-003` (ADR 0005 — virtual-mic publishing): **install path changed from `~/Library/Audio/Plug-Ins/HAL/` to `/Library/Audio/Plug-Ins/HAL/`** (system-domain only, root-owned — Apple staff forum response); install now requires admin escalation via `script/install-driver.sh`. **`launchctl kickstart -k coreaudiod` replaced with `sudo killall coreaudiod`** (Apple restricted `-k` in macOS 14.4). **Ad-hoc signing of the `.driver` bundle is required in v1**, not deferred.
- `infrastructure-002` (ADR 0004 — system-audio capture): "hardened in 14.4" narrative softened to "Apple's own sample (`insidegui/AudioCap`) and current docs target 14.4+" — same floor, more honest justification. Aggregate-device wrapping pattern (`CATapDescription` + `kAudioAggregateDeviceTapListKey`) made explicit. Sandbox-compatibility flagged as an empirical open question.
- `infrastructure-004` (ADR 0008 — build & release tooling): v1 now ad-hoc signs both `.app` and `.driver` (`codesign --sign -`); v2 increment is swapping in Developer ID + notarisation. ADR title and Decision section rewritten accordingly.
- `infrastructure-006` (walking skeleton): install/uninstall steps updated to system-domain path + `killall`. Acceptance criteria now explicitly include three empirical Q&As — does ad-hoc signing work, is the sandbox compatible with Process Tap (deferred to real-Process-Tap task), is the one-`sudo`-prompt install UX acceptable.
- `vision.md` Non-goals: "Not signed/notarised in v1" softened to "Not fully Developer-ID signed and notarised in v1" — the build does ad-hoc.
- `audio-engine/README.md` open questions resolved against the now-amended ADRs.

**ADRs written this session (committed):** none new — strategic ADRs 0001 and 0002 were committed in the prior brainstorm session, and ADRs 0003–0010 remain as drafts inside their respective `type: decision` tasks until `work` commits them.

**Files outside the protocol you should still review:**
- `contexts/infrastructure/todo/infrastructure-003-virtual-mic-publishing-mechanism.md` — most-changed; revisit the Decision section and the new install-script approach
- `contexts/audio-engine/todo/audio-engine-002-mute-effect-on-upstream-capture.md` — new task with the mute/optionality ADR
- `contexts/infrastructure/todo/infrastructure-006-walking-skeleton.md` — empirical questions Q1–Q3 added

---

## 2026-06-05 — Brainstorm: Stimmgabel — virtual mic merging system audio + default mic

**Type:** Brainstorm
**Outcome:** vision created
**BCs identified:** audio-engine, menubar-ui, infrastructure (no design-system BC — rationale in ADR 0002)
**Summary:** Captured Stimmgabel as a single-user macOS menu-bar tool that exposes one virtual input device combining the macOS default mic with all system audio, replacing a brittle BlackHole + LadioCast workflow. Core promise: follows system defaults automatically; mic indicator only lights up while a downstream consumer is reading. Two clear use cases — Zoom + Handy transcription for the author today, and INNOQ ensemble-programming AI workflows for the team eventually (per-Mac install, no server). Two strategic ADRs written (scope, BC split). Architect produced seven foundation ADR drafts covering language, system-audio capture, virtual-mic publishing, mic capture, mute persistence, build tooling, and testing — each landed as a `type: decision` task with the draft in Notes. One walking-skeleton spike task created in infrastructure depending on all seven decisions. Design-system BC deliberately skipped — the entire UI is a menu-bar icon + tiny dropdown of native controls.
**ADRs written (committed in this session):**
- 0001 — Stimmgabel is a single-user, local-only macOS tool
- 0002 — Bounded contexts: audio-engine, menubar-ui, infrastructure (no design-system BC)
**Foundation tasks emitted:**
- `infrastructure/todo/infrastructure-001-language-and-ui-framework.md` (decision, scope global) — drafts ADR 0003
- `infrastructure/todo/infrastructure-002-system-audio-capture-mechanism.md` (decision, scope global) — drafts ADR 0004
- `infrastructure/todo/infrastructure-003-virtual-mic-publishing-mechanism.md` (decision, scope global) — drafts ADR 0005
- `audio-engine/todo/audio-engine-001-microphone-capture-and-default-device-tracking.md` (decision, scope audio-engine) — drafts ADR 0006
- `menubar-ui/todo/menubar-ui-001-mute-state-persistence.md` (decision, scope menubar-ui) — drafts ADR 0007
- `infrastructure/todo/infrastructure-004-build-and-release-tooling.md` (decision, scope global) — drafts ADR 0008
- `infrastructure/todo/infrastructure-005-testing-strategy.md` (decision, scope global) — drafts ADR 0009
- `infrastructure/todo/infrastructure-006-walking-skeleton.md` (spike, depends on all 7 decisions) — the project's first prototype
**Caveats surfaced by the architect (review before locking the ADRs):**
- The system-audio-capture ADR sets minimum macOS at **14.4 (Sonoma)** based on the architect's inline synthesis of the Process Tap API timeline. If any future user is on Ventura or an earlier Sonoma point release, this is a hard block. Confirm with the INNOQ team's macOS baseline before the secondary use-case kicks in.
- The architect synthesized platform knowledge inline rather than running a researcher pass. If implementation surfaces an inconsistency (e.g. Process Tap API behaviour different from described, Audio Server Plugin entitlement requirements changed), invoke the `research` skill to verify before amending the relevant ADR.
- The audio-engine README's open question on whether mute should also suspend the muted side's *upstream capture* (privacy stronger, mic indicator stays off for a muted-mic side) is **not** resolved by these ADRs and is deferred to a future feature task — defaulting to "zero in the mix" for v1.
- First-run permissions UX (microphone TCC prompt, Audio Server Plugin install confirmation, optional "Add to login items") is a future `menubar-ui/todo/` feature task, intentionally not made part of any decision ADR.

---
