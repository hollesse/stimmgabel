---
id: infrastructure-003
title: Decision — virtual-mic publishing mechanism
status: todo
type: decision
context: infrastructure
created: 2026-06-05
completed:
commit:
depends_on: []
blocks: []
tags: [foundation, audio, virtual-device, install]
related_adrs: []
related_research: [macos-audio-platform-2026-06-05]
prior_art: []
---

## Why
The published language to the outside world (Zoom, Handy, OBS) is "a macOS audio input device". This decision picks the mechanism that produces that device, sets the install story, and determines what signing v2 will need.

## What
Commit ADR 0005 capturing: **Audio Server Plugin** (a `.driver` bundle shipped inside the `Stimmgabel.app`, installed into the system-domain `/Library/Audio/Plug-Ins/HAL/` directory at first run via an admin-elevated copy). Not a kext. Plug-in is a thin ring-buffer shim; all DSP / mix logic stays in the app process. App ↔ plug-in IPC via Mach service / XPC (declared in the plug-in Info.plist via `AudioServerPlugIn_MachServices`). Uninstall is `sudo rm -rf` + `sudo killall coreaudiod`.

**Research findings (`macos-audio-platform-2026-06-05`) corrected three things in the architect's original draft:**
1. **Install path is `/Library/Audio/Plug-Ins/HAL/`, not `~/Library/Audio/Plug-Ins/HAL/`.** Apple staff confirmed on the developer forums (thread/130985) that Audio Server Plugins install in the system-domain directory only. No primary source documents the user-domain path as supported. **Empirical test recommended early in `infrastructure-006` (walking skeleton) before committing to the install UX.**
2. **`launchctl kickstart -k system/com.apple.audio.coreaudiod` was forbidden in macOS 14.4.** Use **`sudo killall coreaudiod`** instead. The general "force coreaudiod restart to pick up new plug-in" pattern still applies; only the mechanism changed.
3. **Plug-ins need at minimum ad-hoc signing** even for local v1 use. The architect's "unsigned, drag-install, no admin escalation" plan is contradicted by current research. Full Developer ID + notarisation stays a v2 concern, but ad-hoc signing of the `.driver` bundle is required in v1's build pipeline. This change also impacts ADR 0008 (build & release tooling) — see amended `infrastructure-004`.

A fourth nuance (not a correction, just an observation): on current macOS, Apple may now run Audio Server Plugins in their own sandboxed process rather than literally in-process inside `coreaudiod`. This does not change the IPC contract (Mach service / XPC) but it tightens what the plug-in can see (only its bundle and system frameworks — XPC is how it talks out).

## Acceptance criteria
- [ ] `knowledge/decisions/0005-virtual-mic-publishing-mechanism.md` exists with `scope: global`, `status: accepted`.
- [ ] Install / uninstall procedure described well enough that a worker can later turn it into a feature task.
- [ ] `knowledge/index.md` updated under `<!-- adr-global:start -->`.
- [ ] No code changes.

## Notes

Architect draft, **amended on 2026-06-05 to reflect research findings** (see `knowledge/research/macos-audio-platform-2026-06-05.md` claim 3.1 / 3.3 / 3.4). Paste into the ADR with id `0005`, status `accepted`, date `2026-06-05`:

```markdown
---
id: 0005
title: Publish the virtual mic via an Audio Server Plugin installed system-domain with ad-hoc signing
scope: global
status: accepted
date: 2026-06-05
supersedes: []
superseded_by: []
related_tasks: [infrastructure-003]
related_research: [macos-audio-platform-2026-06-05]
---

# ADR 0005: Publish the virtual mic via an Audio Server Plugin installed system-domain with ad-hoc signing

## Context

Stimmgabel's published language to the outside world is "a macOS audio input device" (see context-map.md, open host / published language relationship). Consumer apps (Zoom, Handy, OBS) must see Stimmgabel as a normal input device — discoverable in their device pickers, with a stable identity across app launches and reboots.

There are three mechanisms that can produce a virtual input device on modern macOS:

1. **Audio Server Plugin (`.driver` bundle).** Loaded by `coreaudiod` at startup from `/Library/Audio/Plug-Ins/HAL/` (system domain) or `~/Library/Audio/Plug-Ins/HAL/` (user domain). Not a kernel extension, not subject to kext-blocking SIP rules. Authored against the Audio Server Plugin SDK (a C API).
2. **DriverKit Audio Driver (`.dext`).** Modern, sandboxed user-space driver framework. Requires the **DriverKit / Audio Driver entitlement** which Apple grants on request. Designed for hardware-backed drivers; overkill and wrong shape for a pure virtual device.
3. **Aggregate / multi-output devices created at runtime.** Cannot present arbitrary samples as an input; they only re-route existing devices.

## Decision

Use an **Audio Server Plugin**. Specifically:

- Author one Audio Server Plugin (`Stimmgabel.driver`) that exposes a single input device named "Stimmgabel" with a stable `kAudioDevicePropertyDeviceUID` (`com.innoq.stimmgabel.virtualmic`) so consumers can re-find it across launches.
- **Ship the plug-in inside the app bundle** (`Stimmgabel.app/Contents/Resources/Stimmgabel.driver`).
- The plug-in bundle is **ad-hoc signed** by the build (`codesign --sign -` in the build script — see ADR 0008). Ad-hoc signing is the minimum macOS will load on current versions; it does not require an Apple Developer account. Full Developer ID + notarisation arrives with v2 distribution.
- The plug-in declares its Mach service name in `Info.plist` under `AudioServerPlugIn_MachServices` (Apple Technical Q&A QA1811).
- **Install path: `/Library/Audio/Plug-Ins/HAL/Stimmgabel.driver`** (system-domain, root-owned). The user-domain `~/Library/Audio/Plug-Ins/HAL/` is **not** documented to work for Audio Server Plugins; every shipping reference (BlackHole, Loopback's ACE, Background Music) installs into the system-domain path.
- The first run (or post-build) install is performed by a short helper script — `script/install-driver.sh` — that does `sudo cp -R "$APP/Contents/Resources/Stimmgabel.driver" /Library/Audio/Plug-Ins/HAL/` followed by `sudo killall coreaudiod` to force a reload. Admin password is prompted exactly once per install. **`launchctl kickstart -k system/com.apple.audio.coreaudiod` is no longer supported as of macOS 14.4** (Apple restricted `-k` for ~150 critical system processes including `coreaudiod`); `killall` is the workaround documented by the developer community.
- The app process communicates with the plug-in via **Mach service / XPC** (the plug-in registers the service named in its Info.plist; the app connects to push mix frames into the plug-in's ring buffer when a consumer is reading). Reference patterns: Background Music's `BGMDriver` ↔ `BGMApp` XPC bridge; Apple QA1811.
- **Uninstall** is `sudo rm -rf /Library/Audio/Plug-Ins/HAL/Stimmgabel.driver && sudo killall coreaudiod`. A short `script/uninstall-driver.sh` wraps this so the user does not have to remember the commands.
- For v1, the app does not perform the elevation itself — running the install script after the build is acceptable for a single-user workflow. For v2 (team distribution), the install will become either a `.pkg` installer or an in-app `SMJobBless`-style privileged helper, and full Developer ID + notarisation will land at the same time. **This v1 install UX is the part most worth empirically validating in the walking skeleton (`infrastructure-006`) — see its acceptance criteria.**

**Open question to validate empirically in the walking skeleton:** does an ad-hoc-signed Audio Server Plugin in `/Library/Audio/Plug-Ins/HAL/` actually load and expose a CoreAudio input device on a clean macOS 14.4+ install with SIP enabled? Research sources conflict; the only way to know is to try it.

## Consequences

### Positive
- Apple-supported, well-trodden path. BlackHole, Loopback's ACE, Background Music, and Rogue Amoeba's tools all use this mechanism. Loopback's recent migration to their ARK pipeline confirms the modern architecture is *Process Tap (capture) + aggregate device (mix) + Audio Server Plugin (publish a virtual input)* — exactly what Stimmgabel does.
- Not a kext. No kernel-extension UX, no SIP escalation, no recovery-mode workflow, not on Apple's deprecation list.
- Stable device identity across launches via fixed UID.
- DriverKit explicitly rejected by Apple for virtual audio drivers (`developer.apple.com/forums/thread/736357` — "AudioDriverKit currently does not support virtual audio devices and entitlements will not be granted for those types of audio drivers… the audio server plug-in driver model should continue to be used"). So this isn't just the best path — it's the only blessed path.

### Negative
- The Audio Server Plugin SDK is a C API. Some Objective-C / C glue is unavoidable inside the plug-in target (the rest of the codebase remains pure Swift — see ADR 0003).
- **v1 install is not "drag-install".** Because the install path is `/Library/Audio/Plug-Ins/HAL/` (system-domain), v1 requires an admin password prompt at install time — even for the author. The `script/install-driver.sh` helper makes this one prompt rather than several, but it is still a real install step. This is worse than the architect's original "just copy to user-domain" plan but matches the platform reality.
- Restarting `coreaudiod` (`sudo killall coreaudiod`) interrupts every running audio app on the Mac for ~1 second. v1 does this only on install / upgrade / uninstall, which is acceptable but worth telling the user about in the install script's output.
- Cross-process Mach/XPC adds a small fixed latency between the app's mix output and the plug-in's emission. No primary benchmark exists; "fine for voice, not for music" is the rule-of-thumb. Acceptable for Stimmgabel (music production is a declared non-goal in `vision.md`); measure if it ever feels sluggish.
- Ad-hoc signing is required even for v1 — the architect's "unsigned" baseline was wrong; signing pressure on macOS has only tightened. v2 still levels up to full Developer ID + notarisation; v1 ad-hoc gets us out of "completely unsigned" but does not satisfy a clean Gatekeeper run on a machine that did not build the bundle.
- The plug-in install location is global to the Mac. If Stimmgabel.driver is left behind after an uninstall (or after the app is deleted without running the uninstall script), it will remain registered with `coreaudiod` on every reboot. The uninstall script is the documented cleanup; the app may also surface a "Uninstall driver" menu item in the menu bar.

### Neutral
- The plug-in does no DSP; it is a thin shim that exposes a ring buffer as a CoreAudio input device. All mix logic stays in the app process, in the audio-engine BC. This keeps the plug-in small and easy to sign separately later.

## Alternatives considered

- **DriverKit `.dext`.** Rejected. Requires the Audio Driver entitlement from Apple. Heavier sandbox model, harder to debug, designed for hardware-backed drivers. Pure overkill for a virtual mic.
- **Run-time aggregate device.** Rejected. Aggregate devices cannot present arbitrary samples; they can only combine existing physical devices.
- **Re-use BlackHole as the publishing layer.** Rejected. Defeats the project's purpose (replacing the BlackHole stack) and re-introduces the brittleness Stimmgabel exists to eliminate.

## References
- `vision.md` — virtual mic ubiquitous-language entry
- `audio-engine/README.md` — virtual-mic publishing open question
- `context-map.md` — open host / published language relationship with consumer apps
- `knowledge/research/macos-audio-platform-2026-06-05.md` — verified install path, ad-hoc signing requirement, and `killall coreaudiod` workaround
- Apple Developer Forums thread/130985 — staff response: install path is `/Library/Audio/Plug-Ins/HAL/`
- Apple Developer Forums thread/736357 — DriverKit not granted for virtual audio
- Apple Technical Q&A QA1811 — `AudioServerPlugIn_MachServices` IPC pattern
- Kevin M. Cox (Mar 2024) — `launchctl kickstart -k` restricted in macOS 14.4
```
