---
id: infrastructure-003
title: Decision — virtual-mic publishing mechanism
status: done
type: decision
context: infrastructure
created: 2026-06-05
completed: 2026-06-05
commit:
depends_on: []
blocks: []
tags: [foundation, audio, virtual-device, install]
related_adrs: [0005]
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
- [x] `knowledge/decisions/0005-virtual-mic-publishing-mechanism.md` exists with `scope: global`, `status: accepted`.
- [x] Install / uninstall procedure described well enough that a worker can later turn it into a feature task.
- [ ] `knowledge/index.md` updated under `<!-- adr-global:start -->` — handled by orchestrator.
- [x] No code changes.

## Notes

ADR 0005 written at `.agentheim/knowledge/decisions/0005-virtual-mic-publishing-mechanism.md`.

## Outcome

ADR 0005 written capturing the Audio Server Plugin mechanism for virtual mic publishing. Install procedure documented as `script/install-driver.sh` (`sudo cp -R` + `sudo killall coreaudiod`); uninstall as `script/uninstall-driver.sh` (`sudo rm -rf` + `sudo killall coreaudiod`). Three research corrections applied: system-domain install path only, `killall coreaudiod` instead of forbidden `launchctl kickstart -k`, and ad-hoc signing required for v1. Open empirical question deferred to `infrastructure-006` walking skeleton.
