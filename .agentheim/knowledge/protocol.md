# Protocol

Chronological log of everything that happens in this project.
Newest entries on top.

---

## 2026-06-15 10:38 -- Work session ended

**Type:** Work / Session end
**Completed:** 1 (first-try PASS: 1 [audio-engine-008], re-dispatched: 0, skipped: 0)
**Bounced:** 0
**Failed:** 0
**Escalated after verification:** 0
**Commits:** 1 (7bd4d42 audio-engine-008)

---

## 2026-06-15 10:38 -- Task verified and completed: audio-engine-008 - Device names always visible

**Type:** Work / Task completion
**Task:** audio-engine-008 - Device names always visible — read system defaults independent of consumer attachment
**Summary:** New DefaultDeviceMonitor observes default input + output via HAL property listeners on the system object, independent of capture lifecycle. AudioPipeline.currentMicDeviceName / currentSystemAudioDeviceName delegate to the monitor. Plug AirPods → names update in dropdown within ~1 s without restart.
**Verification:** PASS (iteration 1)
**Commit:** 7bd4d42
**Files changed:** 6 (DefaultDeviceMonitor + tests new; AudioPipeline / MicAdapter / AppViewModelTests + audio-engine README modified)
**Tests added:** 12 (75 → 87 total)
**ADRs written:** none

---

## 2026-06-15 10:31 -- Batch started: [audio-engine-008]

**Type:** Work / Batch start
**Tasks:** audio-engine-008 - Device names always visible — read system defaults independent of consumer attachment
**Parallel:** no (1 worker)

---

## 2026-06-15 10:26 -- Model / Captured: audio-engine-008 - Device names always visible

**Type:** Model / Capture
**BC:** audio-engine
**Filed to:** todo
**Summary:** Mic + System-audio device names should be visible in the dropdown regardless of consumer attachment. New DefaultDeviceMonitor uses HAL property listeners on kAudioHardwarePropertyDefault{Input,Output}Device; AudioPipeline delegates currentMic/SystemAudioDeviceName to it. Extends ADR 0006 pattern to also feed the UI in idle state.

---

## 2026-06-10 -- Work session ended

**Type:** Work / Session end
**Completed:** 1 (first-try PASS: 0, re-dispatched: 1 [menubar-ui-005 — iteration 1 caught missing README update, iteration 2 passed], skipped: 0)
**Bounced:** 0
**Failed:** 0
**Escalated after verification:** 0
**Commits:** 1 (5622639 menubar-ui-005)

---

## 2026-06-10 -- Task verified and completed: menubar-ui-005 - Mic gain slider

**Type:** Work / Task completion
**Task:** menubar-ui-005 - Mic gain slider — adjustable mic level, normalized to default, no persistence
**Summary:** AppViewModel gained micGain: Float = 3.0 with didSet propagation; MenuBarView shows a "Mic volume" slider (0–200%, normalized: 3.0 = 100%) below the sys audio slider; README updated. 75 tests pass.
**Verification:** PASS (iteration 2 — iteration 1 caught missing README update)
**Commit:** 5622639
**Files changed:** 4 (AppViewModel, MenuBarView, AppViewModelTests + README)
**Tests added:** 2
**ADRs written:** none

---

## 2026-06-10 -- Verification failed: menubar-ui-005 - Mic gain slider

**Type:** Work / Verification failure
**Task:** menubar-ui-005 - Mic gain slider
**Iteration:** 1 of 3
**Reasons:** BC README not updated — README still headed "menubar-ui-004"; micGain property and Mic volume slider not catalogued
**Iteration hint:** likely-fixable
**Next:** re-dispatched worker

---

## 2026-06-10 -- Batch started: [menubar-ui-005]

**Type:** Work / Batch start
**Tasks:** menubar-ui-005 - Mic gain slider — adjustable mic level, normalized to default, no persistence
**Parallel:** no (1 worker)

---

## 2026-06-10 -- Model / Promoted: menubar-ui-005 - Mic gain slider

**Type:** Model / Promote
**BC:** menubar-ui
**From → To:** backlog → todo
**Summary:** Refined spec: display normalized to default (3.0 = 100%), range 0–6 step 0.3, prior_art links menubar-ui-004; dependency on menubar-ui-004 cleared (now done).

---

## 2026-06-10 -- Work session ended

**Type:** Work / Session end
**Completed:** 1 (first-try PASS: 1 [menubar-ui-004], re-dispatched: 0, skipped: 0)
**Bounced:** 0
**Failed:** 0
**Escalated after verification:** 0
**Commits:** 1 (059f89a menubar-ui-004)

---

## 2026-06-10 -- Task verified and completed: menubar-ui-004 - System audio gain slider

**Type:** Work / Task completion
**Task:** menubar-ui-004 - System audio gain slider — adjustable output level, no persistence
**Summary:** Added sysAudioGain: Float (default 1.0, range 0–2) to AudioPipeline applied per-frame in forwardMixed(); AppViewModel exposes it as @Published with didSet propagation; MenuBarView shows a labeled system audio volume slider. 72 tests pass (was 68).
**Verification:** PASS (iteration 1 — verifier false-positive on orchestrator-owned protocol.md/INDEX.md changes in diff; worker FILE_LIST confirmed those were orchestrator changes)
**Commit:** 059f89a
**Files changed:** 5
**Tests added:** 6 (4 AudioPipelineTests + 2 AppViewModelTests)
**ADRs written:** none

---

## 2026-06-10 -- Batch started: [menubar-ui-004]

**Type:** Work / Batch start
**Tasks:** menubar-ui-004 - System audio gain slider — adjustable output level, no persistence
**Parallel:** no (1 worker)

---

## 2026-06-05 23:15 -- Work session ended

**Type:** Work / Session end
**Completed:** 1 (first-try PASS: 0, re-dispatched: 1 [infrastructure-009 — verifier iteration 1 caught missing HEADER_SEARCH_PATHS in pbxproj, orchestrator fixed, iteration 2 passed], skipped: 0)
**Bounced:** 0
**Failed:** 0
**Escalated after verification:** 0
**Commits:** 1 (073c233 infrastructure-009)

---

## 2026-06-05 23:10 -- Task verified and completed: infrastructure-009 - Driver IPC macOS 26 fix

**Type:** Work / Task completion
**Task:** infrastructure-009 - Driver IPC — replace XPC with POSIX SHM + Darwin notify (macOS 26 fix)
**Summary:** Replaced broken XPC Mach service IPC (macOS 26 Remote Driver Service sandbox) with POSIX SHM ring buffer + Darwin notify signals; SGSharedAudio.h defines shared layout; SHMDriverIPCConnection replaces XPCDriverIPCConnection; 66 tests pass.
**Verification:** PASS (iteration 2 — iteration 1 caught missing HEADER_SEARCH_PATHS in pbxproj)
**Commit:** 073c233
**Files changed:** 11
**Tests added:** 0
**ADRs written:** 0012-driver-ipc-macos26-shm-notifications.md

---

## 2026-06-05 22:30 -- Batch started: [infrastructure-009]

**Type:** Work / Batch start
**Tasks:** infrastructure-009 - Driver IPC — replace XPC with POSIX SHM + Darwin notify (macOS 26 fix)
**Parallel:** no (1 worker)

---

## 2026-06-05 19:20 -- Work session ended

**Type:** Work / Session end
**Completed:** 2 (first-try PASS: 2 [menubar-ui-002, menubar-ui-003], re-dispatched: 0, skipped: 0)
**Bounced:** 0
**Failed:** 0
**Escalated after verification:** 0
**Commits:** 2 (fcfadaa menubar-ui-002, 52707e2 menubar-ui-003)

---

## 2026-06-05 19:15 -- Task verified and completed: menubar-ui-003 - Status indicator

**Type:** Work / Task completion
**Task:** menubar-ui-003 - Status indicator — consumer attached state and current device names in the dropdown
**Summary:** Status section added to the MenuBarView dropdown showing consumer state ("● Active" / "○ Idle — no app reading") and current device names. AudioPipeline now exposes consumerActive, currentMicDeviceName, currentSystemAudioDeviceName sourced from adapter-level CoreAudio property reads; AppViewModel proxies these for SwiftUI.
**Verification:** PASS (iteration 1)
**Commit:** 52707e2
**Files changed:** 10
**Tests added:** 6
**ADRs written:** none

---

## 2026-06-05 18:55 -- Batch started: [menubar-ui-003]

**Type:** Work / Batch start
**Tasks:** menubar-ui-003 - Status indicator — consumer attached state and current device names in the dropdown
**Parallel:** no (1 worker)

---

## 2026-06-05 18:50 -- Task verified and completed: menubar-ui-002 - Mute toggles

**Type:** Work / Task completion
**Task:** menubar-ui-002 - Mute toggles — wire mic-side and system-audio-side mute to AudioPipeline, persist via UserDefaults
**Summary:** Implemented mute toggles wired to AudioPipeline with UserDefaults persistence via MutePreferences, AppViewModel, and updated MenuBarView/StimmgabelApp — mute state survives restarts and the menu-bar icon reflects idle/active/muted states using SF Symbols.
**Verification:** PASS (iteration 1)
**Commit:** fcfadaa
**Files changed:** 11
**Tests added:** 19
**ADRs written:** none

---

## 2026-06-05 18:30 -- Batch started: [menubar-ui-002]

**Type:** Work / Batch start
**Tasks:** menubar-ui-002 - Mute toggles — wire mic-side and system-audio-side mute to AudioPipeline, persist via UserDefaults
**Parallel:** no (1 worker)

---

## 2026-06-05 18:25 -- Work session ended

**Type:** Work / Session end
**Completed:** 1 (first-try PASS: 1 [audio-engine-006], re-dispatched: 0, skipped: 0)
**Bounced:** 0
**Failed:** 0
**Escalated after verification:** 0
**Commits:** 1 (933eeae audio-engine-006)

---

## 2026-06-05 18:20 -- Task verified and completed: audio-engine-006 - Output adapter

**Type:** Work / Task completion
**Task:** audio-engine-006 - Output adapter — XPC client that writes mix frames into the driver ring buffer and handles lazy activation
**Summary:** Implemented `DriverOutputAdapter` — XPC client to `com.innoq.stimmgabel.driver`, 512-frame render timer pushing `pipeline.mix()` as raw float32 to driver ring buffer, `setConsumerActive` → `consumerAttached()`/`consumerDetached()` lazy activation; `DriverIPCConnection` protocol seam enables 7 new Tier-1 tests with fake XPC stub.
**Verification:** PASS (iteration 1)
**Commit:** 933eeae
**Files changed:** 4
**Tests added:** 7
**ADRs written:** none

---

## 2026-06-05 18:00 -- Batch started: [audio-engine-006]

**Type:** Work / Batch start
**Tasks:** audio-engine-006 - Output adapter — XPC client that writes mix frames into the driver ring buffer and handles lazy activation
**Parallel:** no (1 worker)

---

## 2026-06-05 17:55 -- Work session ended

**Type:** Work / Session end
**Completed:** 1 (first-try PASS: 1 [audio-engine-005], re-dispatched: 0, skipped: 0)
**Bounced:** 0
**Failed:** 0
**Escalated after verification:** 0
**Commits:** 1 (7468c6d audio-engine-005)

---

## 2026-06-05 17:50 -- Task verified and completed: audio-engine-005 - Mix

**Type:** Work / Task completion
**Task:** audio-engine-005 - Mix — combine mic side and system-audio side into a single float32 stereo buffer
**Summary:** Introduced `Mixer` with per-side `StagingBuffer` objects (os_unfair_lock-protected), wired both upstream adapter `onBuffer` deliveries into the mixer in `AudioPipeline.init`, and exposed `AudioPipeline.mix(frameCount:) -> [Float]` as the driver-cadence entry point; muted sides contribute zero, absent sides are treated as silence, and per-side gain slots are preserved for v2 faders.
**Verification:** PASS (iteration 1)
**Commit:** 7468c6d
**Files changed:** 5
**Tests added:** 5
**ADRs written:** none

---

## 2026-06-05 17:35 -- Batch started: [audio-engine-005]

**Type:** Work / Batch start
**Tasks:** audio-engine-005 - Mix — combine mic side and system-audio side into a single float32 stereo buffer
**Parallel:** no (1 worker)

---

## 2026-06-05 17:30 -- Model / Promoted: audio-engine-005 - Mix

**Type:** Model / Promote
**BC:** audio-engine
**From → To:** backlog → todo
**Notes:** Dependencies audio-engine-003 (Process Tap) and audio-engine-004 (MicAdapter) both done in previous work session; task fully specified with Tier-1 acceptance criteria.

---

## 2026-06-05 17:25 -- Work session ended

**Type:** Work / Session end
**Completed:** 3 (first-try PASS: 2 [infrastructure-008, audio-engine-004], re-dispatched: 1 [audio-engine-003 — verifier false positive from parallel execution])
**Bounced:** 0
**Failed:** 0
**Escalated after verification:** 0
**Commits:** 3 (bb3e71a infrastructure-008, 1394b39 audio-engine-003, 29c1548 audio-engine-004)

---

## 2026-06-05 17:20 -- Task verified and completed: audio-engine-004 - Mic capture

**Type:** Work / Task completion
**Task:** audio-engine-004 - Mic capture — HAL IOProc on default input device, rebind on default-input change
**Summary:** MicAdapter implemented as CoreAudio HAL IOProc on default input device with AVCaptureDevice TCC prompt, AudioConverter format reconciliation to 48kHz/float32/stereo, and transparent rebind on kAudioHardwarePropertyDefaultInputDevice change via serial dispatch queue; 4 new Tier-1 tests.
**Verification:** PASS (iteration 1)
**Commit:** 29c1548
**Files changed:** 3
**Tests added:** 4
**ADRs written:** none

---

## 2026-06-05 17:05 -- Batch started: [audio-engine-004]

**Type:** Work / Batch start
**Tasks:** audio-engine-004 - Mic capture — HAL IOProc on default input device, rebind on default-input change
**Parallel:** no (1 worker)

---

## 2026-06-05 17:00 -- Task verified and completed: audio-engine-003 - System-audio capture

**Type:** Work / Task completion
**Task:** audio-engine-003 - System-audio capture — Process Tap + aggregate device, rebind on default-output change
**Summary:** SystemAudioAdapter implemented as CATapDescription global Process Tap wrapped in aggregate device, with IOProc buffer delivery in 48 kHz / float32 / non-interleaved stereo and automatic rebind on default-output change; UpstreamCaptureAdapter extended with onBuffer; AudioPipeline wired with onSystemAudioBuffer/onMicBuffer; 8 new Tier-1 tests.
**Verification:** PASS (iteration 2 — iteration 1 was false positive from parallel execution)
**Commit:** 1394b39
**Files changed:** 5
**Tests added:** 8
**ADRs written:** none

---

## 2026-06-05 16:55 -- Verification failed: audio-engine-003 - System-audio capture

**Type:** Work / Verification failure
**Task:** audio-engine-003 - System-audio capture — Process Tap + aggregate device
**Iteration:** 1 of 3
**Reasons:** False positives from parallel execution — INDEX.md changes attributed to worker but made by orchestrator; Package.swift DriverIPC additions attributed to worker but made by infrastructure-008 worker (now committed at bb3e71a)
**Iteration hint:** likely-fixable
**Next:** re-dispatched worker (iteration 2)

---

## 2026-06-05 16:55 -- Task verified and completed: infrastructure-008 - Driver IPC

**Type:** Work / Task completion
**Task:** infrastructure-008 - Driver IPC — Mach service, ring buffer, XPC server in Stimmgabel.driver
**Summary:** Stimmgabel.driver exposes XPC server on com.innoq.stimmgabel.driver (Info.plist declared), backed by 4096-frame lock-free ring buffer; DoIOOperation drains ring buffer instead of emitting silence; StartIO/StopIO send setConsumerActive signals; 7 new Tier-1 ring buffer unit tests pass.
**Verification:** PASS (iteration 1)
**Commit:** bb3e71a
**Files changed:** 8
**Tests added:** 7
**ADRs written:** 0011-driver-ipc-ring-buffer-design.md

---

## 2026-06-05 16:15 -- Batch started: [infrastructure-008, audio-engine-003]

**Type:** Work / Batch start
**Tasks:** infrastructure-008 - Driver IPC (Mach service, ring buffer, XPC server), audio-engine-003 - System-audio capture (Process Tap + aggregate device)
**Parallel:** yes (2 workers)

---

## 2026-06-05 16:00 -- Model / Promoted: infrastructure-008, audio-engine-003, audio-engine-004

**Type:** Model / Promote (batch)
**From → To:** backlog → todo (all three)
- infrastructure-008 — Driver IPC (Mach service, ring buffer, XPC server); related_research updated with macOS 26 ASP research
- audio-engine-003 — System-audio capture (Process Tap + aggregate device)
- audio-engine-004 — Mic capture (HAL IOProc + default-device tracking)

---

## 2026-06-05 15:30 -- Model / Captured: infrastructure-008, audio-engine-003–006, menubar-ui-002–003

**Type:** Model / Capture
**BCs:** infrastructure, audio-engine, menubar-ui
**Filed to:** backlog (all 7)
**Summary:** Captured the full Feature Phase 1 task set. infrastructure-008 wires the driver's Mach
service + ring buffer + XPC server. audio-engine-003/004 implement system-audio and mic capture.
audio-engine-005 mixes both sides. audio-engine-006 is the XPC client + lazy-activation bridge.
menubar-ui-002 adds mute toggles with persistence. menubar-ui-003 adds the status indicator.
Dependency chain: 003/004 → 005 → 006 (parallel with i-008) → menubar tasks.

---

## 2026-06-05 13:10 -- Bug fixed: infrastructure-007 — StimmgabelDriver QueryInterface

**Type:** Work / Bug fix
**Task:** infrastructure-007 — StimmgabelDriver QueryInterface memcmp compares stack pointer instead of UUID bytes
**Summary:** `memcmp(&inUUID, …)` replaced with `CFUUIDBytes uuidBytes = CFUUIDGetUUIDBytes(inUUID); memcmp(&uuidBytes, …)`. QueryInterface now returns S_OK for the correct interface UUID; coreaudiod can acquire the driver and expose the Stimmgabel device. Q1 empirical answer updated to Yes. Q3: single sudo prompt confirmed acceptable.
**Commit:** (pending)
**Files changed:** 3

---

## 2026-06-05 13:00 -- Work session ended

**Type:** Work / Session end
**Completed:** 9 (first-try PASS: 1 [infrastructure-006], skipped: 8 [all ADR decision tasks])
**Bounced:** 0
**Failed:** 0
**Escalated after verification:** 0
**Verification failures recovered:** 1 (infrastructure-002 iteration 1 — worker modified INDEX.md; re-dispatched, iteration 2 passed skip gate)
**Commits:** 13 (9 task commits + 4 housekeeping/chore commits)

---

## 2026-06-05 12:55 -- Task verified and completed: infrastructure-006 - Walking skeleton — minimal end-to-end audio path

**Type:** Work / Task completion
**Task:** infrastructure-006 - Walking skeleton — minimal end-to-end audio path
**Summary:** Stimmgabel.app compiles with ad-hoc-signed embedded Stimmgabel.driver (emits silence); AudioPipeline state machine has 10 passing Tier-1 unit tests; script/build produces dist/Stimmgabel.app with both bundles passing codesign --verify --verbose. Run/install acceptance criteria deferred to manual verification on a real Mac. Root README.md written. Infrastructure README Q1-Q3 empirical answers recorded.
**Verification:** PASS (iteration 1)
**Commit:** (pending)
**Files changed:** 19
**Tests added:** 10
**ADRs written:** none

---

## 2026-06-05 12:42 -- Batch started: [infrastructure-006]

**Type:** Work / Batch start
**Tasks:** infrastructure-006 - Walking skeleton — minimal end-to-end audio path
**Parallel:** no (1 worker — only remaining task; this is the first code task)

---

## 2026-06-05 12:38 -- Task completed (verification skipped): infrastructure-005 - Decision — testing strategy

**Type:** Work / Task completion
**Task:** infrastructure-005 - Decision — testing strategy
**Summary:** ADR 0009 written: three-tier strategy — Tier 1 XCTest unit tests on CI with adapter-protocol fakes (mix logic, state machine, mute persistence, UI projection), Tier 2 live-audio integration on a real Mac (gated by env var), Tier 3 manual smoke checklist per release. Adapter protocols at platform integration points is the Tier 1 structural cost. Scope: global.
**Verification:** SKIPPED — decision-only task (type: decision, FILES_CHANGED == 1, single ADR file)
**Commit:** (pending)
**Files changed:** 1
**ADRs written:** 0009-testing-strategy.md

---

## 2026-06-05 12:35 -- Batch started: [infrastructure-005]

**Type:** Work / Batch start
**Tasks:** infrastructure-005 - Decision — testing strategy
**Parallel:** no (1 worker)

---

## 2026-06-05 12:32 -- Task completed (verification skipped): infrastructure-004 - Decision — build & release tooling

**Type:** Work / Task completion
**Task:** infrastructure-004 - Decision — build & release tooling
**Summary:** ADR 0008 written: Package.swift defines AudioEngine + MenubarUI SPM products; App/Stimmgabel.xcodeproj has app + StimmgabelDriver targets; xcodebuild CLI. v1 ad-hoc-signs both .app and .driver (CODE_SIGN_IDENTITY=-); v2 is a configuration swap to Developer ID + notarytool. Scope: global.
**Verification:** SKIPPED — decision-only task (type: decision, FILES_CHANGED == 1, single ADR file)
**Commit:** (pending)
**Files changed:** 1
**ADRs written:** 0008-build-and-release-tooling.md

---

## 2026-06-05 12:28 -- Batch started: [infrastructure-004]

**Type:** Work / Batch start
**Tasks:** infrastructure-004 - Decision — build & release tooling
**Parallel:** no (1 worker)

---

## 2026-06-05 12:26 -- Task completed (verification skipped): infrastructure-003 - Decision — virtual-mic publishing mechanism

**Type:** Work / Task completion
**Task:** infrastructure-003 - Decision — virtual-mic publishing mechanism
**Summary:** ADR 0005 written: Audio Server Plugin published to system-domain `/Library/Audio/Plug-Ins/HAL/` with ad-hoc signing, Mach/XPC ring-buffer IPC, script/install-driver.sh and script/uninstall-driver.sh helpers. DriverKit and aggregate-device alternatives rejected. Scope: global.
**Verification:** SKIPPED — decision-only task (type: decision, FILES_CHANGED == 1, single ADR file)
**Commit:** (pending)
**Files changed:** 1
**ADRs written:** 0005-virtual-mic-publishing-mechanism.md

---

## 2026-06-05 12:22 -- Batch started: [infrastructure-003]

**Type:** Work / Batch start
**Tasks:** infrastructure-003 - Decision — virtual-mic publishing mechanism
**Parallel:** no (1 worker)

---

## 2026-06-05 12:20 -- Task completed (verification skipped): infrastructure-002 - Decision — system-audio capture mechanism

**Type:** Work / Task completion
**Task:** infrastructure-002 - Decision — system-audio capture mechanism
**Summary:** ADR 0004 written: CoreAudio Process Tap API for system-audio capture, macOS 14.4 minimum. Three research-driven corrections applied (API floor justification, CATapDescription aggregate-device wrapping pattern, sandbox compatibility as open empirical question). Scope: global.
**Verification:** SKIPPED — decision-only task (type: decision, FILES_CHANGED == 1, single ADR file; prior iteration's verifier confirmed ADR content correct)
**Commit:** (pending)
**Files changed:** 1
**ADRs written:** 0004-system-audio-capture-mechanism.md

---

## 2026-06-05 12:18 -- Verification failed: infrastructure-002 - Decision — system-audio capture mechanism

**Type:** Work / Verification failure
**Task:** infrastructure-002 - Decision — system-audio capture mechanism
**Iteration:** 1 of 3
**Reasons:** Worker modified knowledge/index.md — INDEX files are owned by the work skill, not workers
**Iteration hint:** likely-fixable
**Next:** re-dispatched worker

---

## 2026-06-05 12:15 -- Task completed (verification skipped): audio-engine-002 - Decision — mute effect on upstream capture

**Type:** Work / Task completion
**Task:** audio-engine-002 - Decision — mute effect on upstream capture
**Summary:** ADR 0010 written: v1 ships "zero in the mix"; six architectural constraints (per-side UpstreamCaptureAdapter protocol with independent start()/stop(), mute in AudioPipeline not adapters, serial state queue, idempotent toggles, mix tolerates silent side) preserve a half-day v2 suspend-on-mute path.
**Verification:** SKIPPED — decision-only task (type: decision, FILES_CHANGED == 1, single ADR file)
**Commit:** (pending)
**Files changed:** 1
**ADRs written:** 0010-mute-effect-on-upstream-capture.md

---

## 2026-06-05 12:10 -- Batch started: [infrastructure-002, audio-engine-002]

**Type:** Work / Batch start
**Tasks:** infrastructure-002 - Decision — system-audio capture mechanism, audio-engine-002 - Decision — mute effect on upstream capture
**Parallel:** yes (2 workers)

---

## 2026-06-05 12:04 -- Task verified and completed: menubar-ui-001 - Decision — mute-state persistence

**Type:** Work / Task completion
**Task:** menubar-ui-001 - Decision — mute-state persistence
**Summary:** ADR 0007 written: UserDefaults.standard behind a MutePreferences value type persists per-side mute booleans. BC README open question resolved. BC-local to menubar-ui.
**Verification:** PASS (iteration 1)
**Commit:** (pending)
**Files changed:** 2
**Tests added:** 0
**ADRs written:** 0007-mute-state-persistence.md

---

## 2026-06-05 12:02 -- Task completed (verification skipped): infrastructure-001 - Decision — language & UI framework

**Type:** Work / Task completion
**Task:** infrastructure-001 - Decision — language & UI framework
**Summary:** ADR 0003 written: Swift 5.10+ with SwiftUI MenuBarExtra (macOS 13+) as the default UI path, AppKit NSStatusItem+NSMenu as a declared fallback, and a two-target Swift Package layout (AudioEngine UI-free, MenubarUI depending on it) that compiler-enforces the BC boundary.
**Verification:** SKIPPED — decision-only task (type: decision, FILES_CHANGED == 1, single ADR file)
**Commit:** 3f84c47
**Files changed:** 1
**ADRs written:** 0003-language-and-ui-framework.md

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

## 2026-06-08 20:35 -- Model / Captured: audio-engine-007 - Architectural reset Phase 1/2

**Type:** Model / Capture
**BC:** audio-engine
**Filed to:** done (completed work documentation)
**Summary:** Documents the Phase 1/2 architectural reset: removal of mute/render-timer,
driver mono-device fix, sequential gReadPos, and AVAudioEngine mic adoption.
Supersedes audio-engine-002, -004, -005 and menubar-ui-001, -002.

---
