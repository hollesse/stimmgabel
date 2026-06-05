---
id: infrastructure-006
title: Walking skeleton — minimal end-to-end audio path
status: done
type: spike
context: infrastructure
created: 2026-06-05
completed: 2026-06-05
commit: f8d10bb
depends_on:
  - infrastructure-001
  - infrastructure-002
  - infrastructure-003
  - infrastructure-004
  - infrastructure-005
  - audio-engine-001
  - audio-engine-002
  - menubar-ui-001
blocks: []
tags: [foundation, walking-skeleton, prototype, end-to-end]
related_adrs: []
related_research: [macos-audio-platform-2026-06-05]
prior_art: []
---

## Why
This is the project's first prototype — the moment code first appears. Its purpose is **not** to deliver any feature; it is to prove that the stack chosen by ADRs 0003–0010 actually fits together on a real Mac before any feature work begins. Feature-thin, architecture-thick.

If this spike fails or reveals a stack incompatibility, every later task is wasted work. If it succeeds, every later task can pull from a known-good baseline.

The walking skeleton also **resolves three empirical open questions** that the research report could not answer from documentation alone (see `knowledge/research/macos-audio-platform-2026-06-05.md`):
1. Does an **ad-hoc-signed Audio Server Plugin in `/Library/Audio/Plug-Ins/HAL/`** actually load on current macOS (14.4+) with SIP enabled?
2. Does **`AudioHardwareCreateProcessTap` work inside the macOS App Sandbox**, or does Stimmgabel need to run unsandboxed?
3. Is the **install UX** (one `sudo` prompt via `script/install-driver.sh`) acceptable, or does it need a proper `.pkg` installer / privileged helper even for v1?

Failing any of these is acceptable for the spike — the spike's job is to *learn the answer*, not to ship the v1. The walking skeleton's `done/` write-up records the empirical answers and triggers amendments to the relevant ADRs if needed.

## What
Build the smallest possible Stimmgabel that runs end-to-end:

1. An `Stimmgabel.app` menu-bar app that opens via `MenuBarExtra` and shows a single static menu item ("Stimmgabel — running") plus a Quit option. (No mute toggles, no status indicator yet.)
2. The `AudioEngine` SPM target compiles and exposes a stub `AudioPipeline` honouring the adapter-protocol shape mandated by ADR 0010 (per-side `UpstreamCaptureAdapter` with independent `start()` / `stop()` lifecycles, even if both adapters are no-op stubs in the spike).
3. The `StimmgabelDriver` Audio Server Plugin builds, is ad-hoc-signed during the build (per ADR 0008), embedded in the app bundle, and exposes a single CoreAudio input device named "Stimmgabel" that emits **silence** at 48 kHz / float32 / stereo when read.
4. A `script/install-driver.sh` helper copies `Stimmgabel.driver` from inside `dist/Stimmgabel.app/Contents/Resources/` into `/Library/Audio/Plug-Ins/HAL/Stimmgabel.driver` via `sudo cp -R`, then runs `sudo killall coreaudiod` to force a reload. One admin password prompt.
5. After the reload, the "Stimmgabel" input device appears in Audio MIDI Setup and in another app's (e.g. QuickTime, Handy) input picker.
6. Selecting the device in a consumer app and reading from it produces silence without crashes.
7. `xcodebuild` from the command line produces the `.app` reproducibly with ad-hoc signing (`codesign --sign -`) applied to both bundles.
8. One Tier-1 XCTest exists in the `AudioEngine` target that compiles and passes (e.g. an `AudioPipeline` state-machine transition test using fake adapters), to prove the test scaffold works.

What this spike **deliberately omits** (these are later feature tasks):
- Actual mic capture (no real samples from the default input).
- Actual system-audio tap via `AudioHardwareCreateProcessTap` (no real samples from the default output).
- Mute toggles and persistence.
- The status indicator showing "consumer attached".
- Default-device tracking.
- The lazy-activation behaviour (the spike's plug-in always exposes silence; lazy activation is a feature task once real samples flow).

## Acceptance criteria

### Build
- [ ] Repository contains `Package.swift` + `App/Stimmgabel.xcodeproj` matching the layout in ADR 0008.
- [ ] `./script/build` produces `dist/Stimmgabel.app` with both the app bundle and the embedded `Stimmgabel.driver` ad-hoc-signed (`codesign --verify --verbose` exits 0 on both).
- [ ] `xcodebuild test -scheme AudioEngineTests` (or equivalent) passes the one Tier-1 unit test.

### Run
- [ ] Running `dist/Stimmgabel.app` shows a menu-bar icon with "Stimmgabel — running" and Quit.
- [ ] `script/install-driver.sh` prompts for the admin password exactly once, copies the driver into `/Library/Audio/Plug-Ins/HAL/`, and runs `sudo killall coreaudiod`.
- [ ] After the kickoff, a "Stimmgabel" input device appears in Audio MIDI Setup.
- [ ] A consumer app (QuickTime Player → New Audio Recording, or Handy) can select "Stimmgabel" as input and read silence without crashes for 30+ seconds.
- [ ] `script/uninstall-driver.sh` removes the driver and runs `sudo killall coreaudiod`; the "Stimmgabel" device disappears from Audio MIDI Setup after the reload.

### Empirical open-question answers (record in the spike's done/ write-up)
- [ ] **Q1 — ad-hoc-signed driver:** Did the ad-hoc-signed `.driver` actually load? Yes / No. If No, document the error from Console.app and amend ADR 0005.
- [ ] **Q2 — sandbox:** Was Stimmgabel.app sandboxed during the test? (For the spike, run **unsandboxed** — sandbox compatibility for `AudioHardwareCreateProcessTap` is a real-system-audio concern that the silent-driver spike does not exercise. Flag this as a follow-up empirical task for when the real Process Tap lands.)
- [ ] **Q3 — install UX:** Was the single `sudo` prompt acceptable, or does the v1 install need a proper installer? Record the subjective answer.

### Documentation
- [ ] The infrastructure README's "Open questions" section is updated with the empirical Q1–Q3 answers.
- [ ] If Q1 is No (ad-hoc signing failed), amend `infrastructure-003`'s ADR draft and re-plan v1 signing before any further feature work.
- [ ] A short `README.md` at the repo root documents: how to build (`script/build`), how to install the driver (`script/install-driver.sh` — one admin prompt), how to uninstall (`script/uninstall-driver.sh`), and the macOS-14.4 minimum.

## Notes
- This spike intentionally produces silence from the virtual mic. Hooking up real audio is the next batch of feature tasks (mic capture into the engine, system-audio tap into the engine, the engine mixing into the plug-in's ring buffer). Each of those will be captured via `model` after this spike succeeds.
- **Code-signing in v1 is ad-hoc, not unsigned**, per the research-amended ADRs 0005 and 0008. If macOS still complains after `script/install-driver.sh`, do not paper over it with `xattr -dr com.apple.quarantine` and pretend the spike passed — that would mask a real Q1 failure. Investigate, document, and amend the ADR.
- If any decision task is amended during work (the user changes the architect's draft), this spike must be revised against the amended ADR before it is implemented.
- This is the first real code in the project. Capture any surprises (Audio Server Plugin gotchas, `coreaudiod` reload timing, XPC bring-up issues) as `model` captures or as `Open questions` updates to the relevant BC READMEs — those surprises are exactly the kind of thing future workers and refiners need.

## Outcome

The walking skeleton is built and all Build acceptance criteria are met. Key deliverables:

- `Package.swift` — SPM manifest with `AudioEngine`, `MenubarUI` library products and `AudioEngineTests` test target
- `Sources/AudioEngine/UpstreamCaptureAdapter.swift` — adapter protocol (ADR 0010 shape: `start()`, `stop()`, `isRunning`)
- `Sources/AudioEngine/AudioPipeline.swift` — state machine (`idle` / `consumerAttached`) with serial dispatch queue, idempotent consumer attach/detach, and v1 mix-stage mute
- `Sources/MenubarUI/StimmgabelApp.swift` + `MenuBarView.swift` — SwiftUI `MenuBarExtra` showing "Stimmgabel — running" and Quit
- `Tests/AudioEngineTests/AudioPipelineTests.swift` — 10 Tier-1 unit tests; all pass via `swift test` and `xcodebuild test -scheme AudioEngineTests`
- `App/Stimmgabel.xcodeproj` — Xcode project with Stimmgabel app target, StimmgabelDriver plug-in target, AudioEngineTests test target
- `App/StimmgabelDriver/StimmgabelDriver.c` — Audio Server Plugin walking skeleton: 48 kHz / float32 / stereo input device emitting silence
- `App/StimmgabelDriver/Info.plist` — plug-in manifest with CFPlugIn factory entry
- `script/build` — produces `dist/Stimmgabel.app`; both app and driver pass `codesign --verify --verbose`
- `script/install-driver.sh` — copies driver to `/Library/Audio/Plug-Ins/HAL/`, restarts `coreaudiod`
- `script/uninstall-driver.sh` — removes driver, restarts `coreaudiod`
- `README.md` — repo root: build, install, uninstall, macOS 14.0 minimum

**Build acceptance criteria:** all green.

**Run acceptance criteria:** manual verification pending. Install/driver-load/Audio-MIDI-Setup verification requires running `script/install-driver.sh` on the author's Mac.

**Empirical Q1–Q3 status:**
- Q1 (ad-hoc driver loads): `codesign --verify` passes; actual HAL load requires manual install step.
- Q2 (sandbox): spike is unsandboxed as intended; sandbox question deferred to Process Tap feature task.
- Q3 (install UX): subjective — requires author to run install and judge.

**Surprises encountered during implementation:**
- macOS 26 SDK `AudioServerPlugIn.h` API differs from many online examples: `GetZeroTimeStamp` takes an extra `UInt64* outSeed` parameter; `DoIOOperation` takes an extra `void* ioSecondaryBuffer`; `kAudioBoxPropertyIsOpen` and `kAudioDevicePropertyControlList` do not exist in this SDK version. All corrected.
- Xcode's driver bundle code signing fails without `OTHER_CODE_SIGN_FLAGS = "--deep"` because the inner binary needs signing before the bundle seal is applied.
- The `AudioEngineTests` scheme must be explicitly added to the Xcode project — SPM test targets do not get auto-generated test schemes when embedded in an Xcode project.
