---
id: audio-engine-002
title: Decision — mute effect on upstream capture (v1: zero in mix; v1 architecture preserves v2 suspend-on-mute)
status: done
type: decision
context: audio-engine
created: 2026-06-05
completed: 2026-06-05
commit: 24df490
depends_on: [audio-engine-001]
blocks: []
tags: [foundation, audio, mute, privacy, mic-indicator]
related_adrs: [0010]
related_research: []
prior_art: []
---
> **⚠ Superseded** by [audio-engine-007](audio-engine-007-phase1-phase2-architectural-reset.md) — Phase 1/2 architectural reset (2026-06-08).


## Why
The audio-engine README leaves explicitly open whether mute should also suspend the muted side's upstream capture. The user accepts the v1 default ("zero in the mix") but does not want it to foreclose v2's stronger behaviour ("suspend capture on mute" — so the macOS mic indicator turns off when only the mic is muted). This task captures the v1 decision **and** the architectural constraints v1 must respect to keep v2 a small, localised change.

## What
Commit ADR 0010 (`scope: audio-engine`, BC-local) capturing: v1 ships with "zero in the mix"; the `AudioPipeline` exposes a per-side `UpstreamCaptureAdapter` protocol with independent `start()` / `stop()` lifecycles; mute lives in `AudioPipeline`, not inside the adapters; all state transitions dispatch onto the engine's single serial queue; mix tolerates a silent / absent buffer from either side; mute toggles are idempotent.

The ADR also names the v2 cost (≈ half a day, contingent on v1 honouring the constraints) and the "revisit when" triggers — most importantly: **before any v2 release that distributes Stimmgabel beyond the author**.

## Acceptance criteria
- [ ] `knowledge/decisions/0010-mute-effect-on-upstream-capture.md` exists with `scope: audio-engine`, `status: accepted`.
- [ ] `contexts/audio-engine/INDEX.md` updated under `<!-- adr-local:start -->`.
- [ ] `contexts/audio-engine/README.md` open question on mute & upstream-capture suspension updated (or removed) to point at ADR 0010.
- [ ] No code changes.

## Outcome

ADR 0010 written at `.agentheim/knowledge/decisions/0010-mute-effect-on-upstream-capture.md` (scope: audio-engine, status: accepted). Documents the v1 decision to zero muted sides in the mix, the six architectural constraints v1 must honour so that v2 "suspend-on-mute" remains a half-day change, the v2 effort estimate, and the "revisit when" triggers. The BC README open question (line 56) was already resolved pointing at ADR 0010.

## Notes

Architect draft (paste into the ADR with id `0010`, status `accepted`, date `2026-06-05`):

```markdown
---
id: 0010
title: Mute behaviour for v1 — zero in the mix, with per-side adapter lifecycle preserved for v2 suspend-on-mute
scope: audio-engine
status: accepted
date: 2026-06-05
supersedes: []
superseded_by: []
related_tasks: [audio-engine-002]
related_research: []
---

# ADR 0010: Mute behaviour for v1 — zero in the mix, with per-side adapter lifecycle preserved for v2 suspend-on-mute

## Context

The audio-engine README defines *mute (per side)* as a binary toggle that drops one side from the mix while the other continues to flow. It leaves explicitly open *how* mute is implemented (README, "Open questions"):

> Whether mute should also suspend the muted side's upstream capture (privacy-positive: no samples even read) or only zero it in the mix (simpler). Default for v1: zero in the mix; revisit.

Two implementations are viable:

1. **Zero in the mix.** Both upstream adapters (mic capture via CoreAudio HAL IOProc — ADR 0006; system-audio capture via Process Tap — ADR 0004) are started whenever any consumer is attached, regardless of per-side mute state. The mix function multiplies a muted side's buffer by zero (or skips its accumulate). Mute is a pure mix-stage concern. Consequence: when only the mic is "muted" but the consumer is reading, the mic IOProc is still running, samples are still being read from the device, and the **macOS microphone indicator stays lit** even though no mic audio reaches the consumer.

2. **Suspend capture on mute.** A muted side's upstream adapter is not opened at all (or is closed when mute is toggled on, reopened when toggled off). Consequence: muting the mic also stops the device IOProc, which means the macOS microphone indicator turns off if only the system-audio side is flowing. Stronger privacy / UX honesty.

The product's stated north star (`vision.md`, "What success looks like") is that the mic indicator behaviour is honest: "The macOS microphone indicator only lights up while a downstream consumer is actually reading from Stimmgabel. It does *not* glow continuously." That promise was written about *idle* (no consumer) vs. *active* (consumer reading); it does not explicitly address the *consumer-reading-but-mic-muted* case. Option 2 would extend that honesty to the muted-mic case.

The user's product judgement, explicitly stated, is that option 1 is acceptable for v1 (the primary user is the author; the brittleness this app replaces does not include a mute-side-indicator-honesty problem), **provided** that v1's architecture does not box v2 out of option 2.

## Decision

**v1 ships with "zero in the mix".** Both upstream adapters run whenever any consumer is attached; the per-side mute toggle is applied at the mix stage.

The v1 implementation **must** respect the following architectural constraints, so that adding "suspend capture on mute" in v2 is a localised code change rather than a structural rewrite:

1. **Each side has its own adapter with an independent lifecycle.** The audio-engine exposes (at minimum, internally) a protocol along the lines of:

   ```
   protocol UpstreamCaptureAdapter {
       func start() throws        // open IOProc / Process Tap, begin delivering buffers
       func stop()                // tear down IOProc / Process Tap, deliver no more buffers
       var isRunning: Bool { get }
   }
   ```

   The mic adapter (HAL IOProc, per ADR 0006) and the system-audio adapter (Process Tap, per ADR 0004) each conform. The `AudioPipeline` aggregate owns one instance of each and treats them symmetrically.

2. **`start()` / `stop()` per adapter is the seam.** v1's `AudioPipeline` calls `start()` on **both** adapters when the first consumer attaches and `stop()` on **both** when the last consumer detaches. v2's change is: also call `stop()` on a single adapter when its side is muted, and `start()` on it when unmuted — nothing else.

3. **Mute toggle handling goes through a single method.** The mute path on `AudioPipeline` (called by `SetSideMute` from menubar-ui) is one method that today writes a boolean used at the mix stage. In v2 the same method additionally calls `stop()` / `start()` on the affected adapter. **Mute state must not be threaded through the adapter implementations themselves in v1** — the adapter does not know about mute. Mute lives in `AudioPipeline`.

4. **State transitions on a single serial queue.** Adapter `start()` / `stop()` calls, consumer-attach/detach transitions, default-device-change rebinds (ADR 0006, ADR 0004), and mute toggles all dispatch onto the engine's serial state queue. This invariant already exists because ADR 0006's HAL property listeners and ADR 0004's tap lifecycle both demand it; this ADR explicitly extends it to cover mute transitions in v2.

5. **Mute changes are idempotent and reentrant-safe.** Muting an already-muted side is a no-op. Unmuting an unmuted side is a no-op. This must hold in v1 (cheap to do at the boolean level) so that v2's `stop()` / `start()` calls inherit the same guarantee for free.

6. **Mix stage tolerates a silent / absent buffer from either side.** The mix already has to handle "no system audio is playing right now" and "no mic plugged in" (per `vision.md` open questions). v1's mix must therefore treat "side X delivered no buffer this cycle" as silence, not as an error. In v2 a muted-and-suspended side delivers nothing; the mix sees this as already-handled silence.

## v2 effort estimate

Given the v1 constraints above are honoured, the architect's estimate for v2 is **small — roughly half a day of focused work**:

- Extend the `AudioPipeline.setSideMute` method to call `stop()` / `start()` on the adapter for the affected side, dispatched on the serial state queue. (~1–2 hours including the idempotency edge cases.)
- One Tier-2 / integration test: with a consumer attached, toggle mic mute on; assert the mic IOProc is torn down (observable as `mic adapter isRunning == false` and, behaviourally, the macOS mic indicator turning off). Toggle mute off; assert the IOProc starts again and the indicator returns. (~2–3 hours including the test scaffolding to drive a consumer attach in test.)
- Brief manual verification on a real machine that the mic indicator behaves as expected. (~30 min.)

This estimate **assumes** the v1 architectural constraints above are met. **It is probably wrong on the low side** if any of these turn up: (a) the macOS mic indicator has hysteresis or caching that delays its turn-off after IOProc stop (will need empirical verification — could push the estimate by a few hours of fiddling), (b) a fast mute/unmute toggle race surfaces a CoreAudio bug under rapid IOProc create/destroy (would need a debounce or coalesce strategy, ~half a day extra), or (c) the system-audio side's Process Tap turns out to have meaningful creation latency, making mute/unmute feel sluggish (would need to reconsider the symmetry and possibly keep the tap warm — that *would* be a structural revisit, but it would be specific to the system-audio side, not a v1-constraint violation).

If the estimate has to grow, it grows into "one day, maybe two" — not into "rewrite the pipeline". That is the property this ADR is buying.

## Revisit when

Revisit and promote v2 (suspend-on-mute) when **any** of these is true:

- The first user feedback complains that the macOS mic indicator glows while their mic is muted.
- Before the first v2 release that distributes Stimmgabel beyond the author (the secondary INNOQ-team audience). The "mic indicator on when muted" behaviour is acceptable for a single user who built the app and knows exactly what is and isn't being read; it is not acceptable as the default for users who did not build it.
- A security/privacy review (formal or informal) of the app flags it.
- We add any analytics or telemetry whose presence makes "mic open but muted" indistinguishable from "mic open and being recorded" to an outside observer.

## Consequences

### Positive
- v1 ships sooner. The mix-stage mute is a one-line change at the mix point and zero changes anywhere else.
- The architectural constraints are mostly a *reaffirmation* of what ADR 0006 and ADR 0004 already mandate (per-side IOProc / Tap lifecycle, serial state queue). The only genuinely new constraint this ADR introduces is "mute lives in AudioPipeline, not in the adapters" — a small and obviously-right shape regardless of v2.
- The seam where v2 will plug in is explicit and named: `AudioPipeline.setSideMute` + the per-adapter `start()` / `stop()`. A future contributor (including future-author) can find it in seconds.

### Negative
- v1 users see the macOS mic indicator while their mic is muted but a consumer is reading. For the primary user (who built the app) this is informed; for any non-author user it is a small honesty gap. This ADR's "Revisit when" trigger forces the gap closed before non-author distribution.
- Both upstream adapters run whenever a consumer is attached, even if one side is permanently muted. Wasted CPU is small (one IOProc cycle and a multiply-by-zero) but non-zero. Acceptable for v1.

### Neutral
- BC-local: neither `menubar-ui` nor `infrastructure` is affected. The `SetSideMute` command shape on the audio-engine boundary is unchanged between v1 and v2 — only the internal implementation differs.

## Alternatives considered

- **Ship v2 (suspend-on-mute) in v1 directly.** Rejected for v1. The lifecycle dance (start/stop a CoreAudio IOProc or a Process Tap in response to a UI toggle, dispatched onto the serial queue, with idempotency and race handling against consumer-attach/detach and default-device rebinds) is real work and real test surface. The product judgement is that the mic-indicator-honesty gain is not worth blocking the v1 ship — but the architecture must not foreclose it.
- **Implement v1 with mute as a flag inside each adapter.** Rejected. That would couple adapter implementations to a UI concept (mute) and would make v2's "don't even open the adapter for a muted side" a leaky change touching every adapter. Keeping mute in `AudioPipeline` keeps adapters pure.
- **Skip the per-side adapter protocol; let `AudioPipeline` call into CoreAudio inline.** Rejected. ADR 0006 and ADR 0004 already mandate per-side IOProc / Tap lifecycle management on a serial queue; a per-side adapter abstraction is the obvious shape that falls out of those two ADRs anyway. Making it explicit in this ADR costs nothing and pays for itself the moment v2 lands.

## References
- `audio-engine/README.md` — open question on mute & upstream-capture suspension (the question this ADR answers)
- `vision.md` — mic-indicator-honesty promise; binary-mute-per-side as the whole mixing surface
- ADR 0006 — mic capture via CoreAudio HAL with property-listener-based default-device tracking; mandates per-side IOProc lifecycle and serial state queue
- ADR 0004 — system-audio capture via CoreAudio Process Tap API; mandates tap create/destroy at consumer-attach/detach
```
