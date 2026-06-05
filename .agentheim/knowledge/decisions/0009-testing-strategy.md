---
id: 0009
title: Three-tier testing — XCTest units on CI, live-audio integration on a real Mac, manual smoke checklist per release
scope: global
status: accepted
date: 2026-06-05
supersedes: []
superseded_by: []
related_tasks: [infrastructure-005]
related_research: []
---

# ADR 0009: Three-tier testing — XCTest units on CI, live-audio integration on a real Mac, manual smoke checklist per release

## Context

Stimmgabel's value sits in a place that is genuinely hard to test in CI: the real-time audio data path runs through a system daemon (`coreaudiod`), depends on TCC-granted permissions a hosted CI runner cannot grant, and produces output (samples emitted to a virtual mic) whose correctness needs another process to consume and check. The audio-engine BC must still be testable enough that we trust mix logic, sample-rate conversion, the lazy-activation state machine, and the default-tracking transitions — none of which require live audio if the engine is structured for testability.

The other two BCs are easier: `menubar-ui` has a tiny projection layer testable in isolation; `infrastructure` has almost no code, mostly assets and build wiring.

## Decision

Three tiers, named explicitly so we know what each one buys us:

### Tier 1: Unit tests (XCTest), run on CI

In scope:
- Mix logic on synthetic sample buffers (silence in → silence out; sine in → sine in mix output; left-muted + right-active → only right contributes).
- Sample-rate / channel-count conversion correctness on canned fixtures.
- The `AudioPipeline` state machine: `idle → consumer-attached → upstream-running` and the reverse, exercised via fakes that play the role of the CoreAudio Tap and HAL Mic capture.
- `MutePreferences` round-trip (write → read → assert) using an isolated `UserDefaults` suite.
- The `menubar-ui` projection: given engine state X, the dropdown model renders Y.

**Out of scope** — these run only as Tier 2:
- Anything that calls `AudioHardwareCreateProcessTap`, `AudioDeviceCreateIOProcID`, or loads the Audio Server Plugin.

Structural requirement: the audio-engine BC exposes adapter protocols for *the platform integration points* (mic capture, system-audio tap, virtual-mic publishing). Production wires the real CoreAudio implementations; tests wire fakes that feed synthetic buffers. This is the only structural cost; everything else falls out for free.

### Tier 2: Live-audio integration tests, real Mac only

XCTest targets gated behind `STIMMGABEL_LIVE_AUDIO_TESTS=1`. They:
- Open the real default input and capture a few seconds of silence; assert non-crashing and roughly-expected sample counts.
- Open a real Process Tap on the default output; pipe a known sine wave through `afplay` and assert the tap receives audio.
- Load the Audio Server Plugin (via `launchctl kickstart coreaudiod` after copying the `.driver` into `~/Library/Audio/Plug-Ins/HAL/`); spawn a small AVFoundation consumer that opens the Stimmgabel device and reads samples; assert samples written by the test into the plug-in's ring buffer arrive at the consumer.

These tests are **not** run on hosted CI. They are run on the author's Mac before a release, and on any other developer's Mac as part of their environment setup.

### Tier 3: Manual smoke checklist, per release

A short Markdown checklist in `contexts/infrastructure/` (initially in `todo/`, archived to `done/` once authored) covering:
- Launch app; menu-bar icon appears.
- Open Zoom (or any consumer); Stimmgabel appears in the device list.
- Select Stimmgabel; speak; assert Zoom hears the voice.
- Play YouTube; assert Zoom hears system audio mixed in.
- Toggle "Mute mic"; assert system audio still flows, mic silenced.
- Plug in / unplug headphones mid-call; assert no interruption to the consumer.
- Close the consumer; assert the macOS mic indicator turns off.

The checklist is the only thing that proves the end-to-end story works. Tier 1 and Tier 2 are necessary but not sufficient.

## Consequences

### Positive
- Honest about what CI can and cannot do for a CoreAudio-integrated app.
- The Tier 1 structural cost (adapter protocols for platform integration points) is small and pays back as the engine grows.
- Tier 2 runs against the actual macOS audio stack — exactly where almost every bug will live.
- Tier 3 is the contract with the user; if the manual checklist passes, the product works.

### Negative
- No "press a button, ship" pipeline. Releases require the author to run Tier 2 + Tier 3 by hand.
- Tier 2 tests are fragile to macOS audio-stack changes (Apple ships point releases that subtly alter CoreAudio behaviour); they will need maintenance.
- Coverage metrics on the audio-engine will look low because the hot paths are exercised only by Tier 2 and Tier 3.

### Neutral
- The Tier 2 / Tier 3 distinction is sharper than usual but reflects reality: some things only work on a logged-in Mac with TCC grants.

## Alternatives considered

- **Try to mock all of CoreAudio in CI.** Rejected. Building a CoreAudio simulator just for tests is more code than the app itself and would mostly verify our own fakes.
- **Skip unit tests; rely entirely on the manual smoke checklist.** Rejected. The mix logic, default-tracking state machine, and mute-state round-trip are exactly the things that benefit most from unit tests, and they are cleanly testable once adapter protocols exist.
- **Add a self-hosted CI runner on a Mac that runs Tier 2.** Possible future move; not warranted for a one-person v1.

## References
- `audio-engine/README.md` — testability mention; aggregates that need state-machine coverage
- `vision.md` — Users: single-user v1, then a small INNOQ team
- ADR 0002 — bounded contexts; this strategy reflects all three BCs
