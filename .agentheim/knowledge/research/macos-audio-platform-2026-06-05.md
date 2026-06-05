---
name: macos-audio-platform-2026-06-05
description: Verification of architect's foundation claims for Stimmgabel (Core Audio Process Tap, ScreenCaptureKit, Audio Server Plugin, DriverKit, MenuBarExtra, IPC) against current Apple docs and 2024-2026 developer reports.
created: 2026-06-05
requested_by: brainstorm
related_bcs: [audio-engine]
related_tasks: []
---

# Research: macOS Audio Platform — verifying foundation claims

## Question
The architect made a set of inline platform claims when scaffolding Stimmgabel. The user cannot evaluate them directly. Cross-check each claim against Apple docs and recent (2024-2026) developer reports, and flag anything that could break the v1 plan.

## Summary
- **Process Tap API:** Available since 14.2, but Apple's own sample (insidegui/AudioCap) and the official docs target **14.4+**. The "14.2 had crashes, 14.4 fixed them" specific narrative is **not directly documented**; what *is* documented is that 14.4 hardened `coreaudiod` against forced restarts. Treat 14.4 as the practical floor.
- **System-wide tap via default output device:** Confirmed pattern (empty `processObjectIDList` global tap), but `launchctl kickstart -k coreaudiod` was broken in 14.4 — `killall coreaudiod` is the workaround.
- **`~/Library/Audio/Plug-Ins/HAL` user-domain unsigned plugin:** **NO CLEAR EVIDENCE**. Every primary source (Apple forums, AudioServerPlugIn.h, BlackHole, Loopback) only documents `/Library/Audio/Plug-Ins/HAL` (system, root-owned). **This is the most fragile claim in the v1 plan and needs empirical testing before committing.**
- **DriverKit for virtual audio:** Confirmed — Apple explicitly will not grant the entitlement for virtual-only drivers; AudioServerPlugIn is the only blessed path.
- **MenuBarExtra:** Confirmed available since macOS 13, confirmed quirky enough that serious apps still drop to NSStatusItem. New regressions reported on macOS 26 Tahoe (`openSettings` broken).
- **2026 landscape shift:** Loopback (Rogue Amoeba) migrated from their Audio Server Plugin (ACE) to a new ARK pipeline on macOS 14.5+ — strong signal that Core Audio Taps + an aggregate device is now the production-quality path for system-audio capture, and the AudioServerPlugIn role is shrinking to "publish a virtual *input* device".

## Findings

### Claim 1.1 — Process Tap API introduced in macOS 14.2

Architect's claim verbatim:
> "Introduced in macOS 14.2 (`AudioHardwareCreateProcessTap` / `kAudioObjectClassProcessTap`)."

**What the web says.** The API symbols exist in 14.2 — a community gist explicitly titled "An example how to use the new Core Audio Tap API in macOS 14.2" [4] and the AudioTee README states "macOS 14.2 or later" [9]. However, Apple's official documentation and Apple's own sample code (Guilherme Rambo's `insidegui/AudioCap`) target macOS 14.4+ [1][2]. The 14.2 vs 14.4 discrepancy is real but the practical floor is 14.4.

**Verdict: PARTIALLY CONFIRMED, see notes.** Symbols ship in 14.2, but every production-grade reference codebase requires 14.4. Use 14.4 as the deployment minimum, not 14.2.

### Claim 1.2 — "14.2 shipped the tap API but had crash bugs that 14.4 fixed"

**What the web says.** I could not find a primary source confirming this specific narrative. Apple's macOS 14.4 release notes are not quoted directly in any source I found citing Process Tap crash fixes. What is well-documented is a *different* 14.4 change: `launchctl kickstart -k` was forbidden for ~150 critical system processes including `com.apple.audio.coreaudiod` [7][13]. Rogue Amoeba's late-2024 post documents general 15.1 Core Audio fixes (CPU regression, exclusive-mode device hogging) but nothing specific to taps [12]. macOS 26.1 (Tahoe) shipped further audio capture fixes (FaceTime/Phone capture, sample-rate-mismatch failures, low-sample-rate regression) [17] — clear evidence the tap pipeline has had bugs across the 14.x → 26.x window, but no source pinpoints the architect's exact 14.2-crash-fixed-in-14.4 story.

**Verdict: NO CLEAR EVIDENCE.** The general intuition (Process Tap stability improved with each point release) is consistent with what's reported, but the specific "14.4 fixed the crashes" claim is not directly attested.

### Claim 1.3 — Tap can be configured against the default output device, capturing all system audio

**What the web says.** Confirmed. The documented pattern: create a `CATapDescription` initialized with an empty process list — e.g. `initStereoGlobalTapButExcludeProcesses([])` or `initMonoGlobalTapButExcludeProcesses` with an empty array — then wrap it in an aggregate device that lists the tap in `kAudioAggregateDeviceTapListKey` [3][6]. "Only the default output device is currently supported for system audio taps" [3].

**Verdict: CONFIRMED.**

### Claim 1.4 — Reachable from a sandboxed app with only `NSMicrophoneUsageDescription` / `NSAudioCaptureUsageDescription`, no screen-capture entitlement, no kext/DriverKit entitlement

**What the web says.** The permission story is confirmed: the tap triggers the TCC prompt controlled by `NSAudioCaptureUsageDescription` in Info.plist [1][2]. No screen-recording entitlement is required (this is the whole point of the API vs. ScreenCaptureKit). No DriverKit/kext entitlement is required. **The sandbox compatibility specifically is *not* explicitly stated in the sources I found.** AudioCap's README does not declare sandbox status [1]. AudioTee is a CLI tool (not sandboxed) [9]. I found no source confirming that a fully App-Sandbox-entitled app can call `AudioHardwareCreateProcessTap` successfully — this should be tested empirically before committing.

**Verdict: PARTIALLY CONFIRMED, see notes.** TCC + Info.plist story is confirmed; the "works inside the App Sandbox" half is NO CLEAR EVIDENCE.

### Claim 1.5 — Tap can be created/destroyed at will (lazy activation)

**What the web says.** No source contradicts this; the API surface (`AudioHardwareCreateProcessTap` / `AudioHardwareDestroyProcessTap`) is symmetric and CATapDescription is a normal `AudioObjectID` once created [3][5].

**Verdict: PARTIALLY CONFIRMED, see notes.** Architecturally plausible and no source contradicts; no source explicitly endorses long-running lazy-create-destroy cycles either.

### Claim 1.6 — Re-creating the tap on `kAudioHardwarePropertyDefaultOutputDevice` change is the supported re-bind pattern

**What the web says.** No source I found explicitly documents "default output device changed → tear down tap and aggregate device → re-create" as an Apple-blessed pattern. It is *consistent* with the design (the tap is bound to a specific output device at creation), and aggregate-device-recreation on route changes is a well-known general Core Audio idiom, but it is not directly attested.

**Verdict: NO CLEAR EVIDENCE.** Likely correct; not documented.

### Claim 2 — ScreenCaptureKit audio-only mode and the screen-recording TCC prompt

Architect's claim verbatim:
> "`SCStreamConfiguration.capturesAudio` exists since macOS 13. An audio-only mode (no screen frames captured) is supported. Even in audio-only mode, it triggers the screen-recording TCC prompt (`NSScreenCaptureUsageDescription`)."

**What the web says.** The `capturesAudio` flag dates to macOS 13 [11]. However, the "audio-only mode" claim is contested: developer forum and blog reports say ScreenCaptureKit does **not** offer a true audio-only mode — "you can capture audio, but you also have to capture screen and just filter the samples out in the callback" [10] and Recall.ai documents "system audio access is tied to a window or capture session" [15]. TCC behavior is confirmed: "ScreenCaptureKit is purely TCC-gated… capture is allowed solely when the user enables your binary under System Settings → Privacy & Security → Screen & System Audio Recording" [11]. Apple has renamed this category in newer macOS to "Screen & System Audio Recording" reflecting that system-audio capture sits under the same TCC bucket [14].

**Verdict: PARTIALLY CONFIRMED, see notes.** TCC prompt = screen-recording bucket is **CONFIRMED**. The "audio-only, no frames" claim is **CONTRADICTED**: SCK still requires you to start a screen capture session and discard the video frames. For Stimmgabel this is mostly irrelevant (the plan uses Core Audio Taps, not SCK), but worth correcting in the design doc.

### Claim 3.1 — Audio Server Plugin loaded by coreaudiod from `/Library/Audio/Plug-Ins/HAL/` (system) or `~/Library/Audio/Plug-Ins/HAL/` (user)

**What the web says.** Apple staff response on the developer forums: "All AudioServerPlugIns should be installed at `/Library/Audio/Plug-Ins/HAL`. If the directory doesn't exist, it is the job of the installer to create it." [8] Multiple secondary sources reiterate the system path and root-ownership requirement [13][16]. **No primary source I found mentions `~/Library/Audio/Plug-Ins/HAL` as a supported install path for AudioServerPlugIns.** Every shipping product (BlackHole [16], Loopback's ACE [18], Background Music) installs to `/Library/`. macOS user community threads searching for `~/Library/Audio/Plug-Ins/HAL` are about *AudioUnit components and HAL hardware plugins*, not AudioServerPlugIns.

**Verdict: CONTRADICTED, see notes.** This is the single most consequential finding for the v1 plan. The user-domain HAL path appears to be either undocumented or non-functional for AudioServerPlugIns. The architect's "unsigned, user-domain, no admin escalation" v1 plan likely will not work — you almost certainly need an installer that writes to `/Library/Audio/Plug-Ins/HAL` with admin escalation. **Verify empirically before committing v1 scope.**

### Claim 3.2 — Audio Server Plugin is not a kext, runs inside coreaudiod, not subject to kext-deprecation

**What the web says.** Confirmed in spirit. AudioServerPlugIns are HAL plugins loaded by `coreaudiod` [13]. One nuance: a more recent Apple forum response indicates that "in current macOS versions, an Audio Server Plugin runs in its own process" [21] — suggesting Apple has moved AudioServerPlugIns from in-process inside `coreaudiod` to a separate sandboxed helper process. Either way: not a kext, not subject to kext blocking, not on Apple's deprecation list.

**Verdict: CONFIRMED** (with a refinement: it may now be its own sandboxed process rather than literally in-process inside `coreaudiod`).

### Claim 3.3 — User-domain HAL path accepts UNSIGNED plug-ins on current macOS (2026) for local dev/personal use

**What the web says.** Several layers of trouble here:

1. The user-domain path itself isn't documented to work (see 3.1).
2. For the system-domain path, signing is generally required for distribution; one 2025 Moonbase article and JUCE forum posts state code signing is "mandatory" in practice [19][22].
3. For *local development*, plug-ins can be loaded with developer-team signing; full Developer ID + notarization is for distribution [20].
4. One older claim ("As of macOS 10.14.5, unsigned audio plugins and CoreAudioPlugins can run without notarization") appears in [19], but this predates the hardened-runtime tightening and the SIP changes in 14.4+.
5. Apple's general direction: macOS 15.1 closed loopholes that previously let users bypass Gatekeeper with Control-click [Hackaday]. Signing pressure has only increased.

**Verdict: CONTRADICTED, see notes.** The combined claim ("user-domain path + unsigned on current macOS 2026") has no supporting primary source and runs against Apple's direction of travel. Even for personal use, expect to need at least an ad-hoc signature and acceptance via System Settings → Privacy & Security on first load. **Treat unsigned v1 as untested; budget signing into v1.**

### Claim 3.4 — `launchctl kickstart -k system/com.apple.audio.coreaudiod` is the supported reload mechanism

**What the web says.** **This was true until macOS 14.4, then broken.** Apple restricted `-k` for ~150 critical system processes in 14.4 and `coreaudiod` is on the list [7][13]. Workarounds: `sudo killall coreaudiod` (still works on 14.4.1+ M1) or `sudo launchctl stop … && sudo launchctl start …` [7].

**Verdict: CONTRADICTED, see notes.** The specific command in the architect's claim no longer works. The general pattern (force a coreaudiod restart to pick up a new plug-in) still applies, but the mechanism changed. Document `killall coreaudiod` as the post-install step.

### Claim 3.5 — BlackHole, Loopback, Audio Hijack virtual devices, Krisp use this mechanism today

**What the web says.** BlackHole: confirmed AudioServerPlugIn at `/Library/Audio/Plug-Ins/HAL/BlackHoleXch.driver`, signed by "MATT INGALLS" [16]. Loopback: historically used their ACE plugin (an AudioServerPlugIn) but **on macOS 14.5+ migrated to a new "Audio Routing Kit (ARK)" approach that no longer requires the user to adjust security settings** [18][23] — strong signal that ARK leans on the Core Audio Taps API for capture, while still publishing a virtual device. Krisp: not directly verified in my searches; treat as unconfirmed.

**Verdict: PARTIALLY CONFIRMED, see notes.** Mechanism still in active use, but the industry leader (Loopback) is moving off the pure-AudioServerPlugIn architecture for capture on macOS 14.5+. For Stimmgabel, the AudioServerPlugIn still has a role: publishing a virtual *input* device. The capture path is increasingly Core Audio Taps.

### Claim 4 — DriverKit `.dext` audio drivers require the audio entitlement, granted on request, overkill for virtual

**What the web says.** **CONFIRMED and stronger than the architect stated.** Apple's official position: "AudioDriverKit currently does not support virtual audio devices and entitlements will not be granted for those types of audio drivers… If a virtual audio driver or device is all that is needed, the audio server plug-in driver model should continue to be used." [24] So it's not just "overkill" — Apple will reject the entitlement application.

**Verdict: CONFIRMED.** Closes off DriverKit entirely as a Stimmgabel option.

### Claim 5.1 — MenuBarExtra since macOS 13

**What the web says.** Confirmed. Introduced at WWDC22, ships in macOS 13 Ventura [25][26].

**Verdict: CONFIRMED.**

### Claim 5.2 — Known quirks (state retention, animation glitches, no programmatic open/close, etc.) may force AppKit fallback

**What the web says.** Heavily confirmed. Reported issues: no programmatic show/hide/toggle in Ventura+ [26][27]; no API to access underlying NSStatusItem or popup NSWindow [26]; `SettingsLink` unreliable; menu doesn't re-render on open (FB13683957/FB13683950 [28]); only image/text in the menu bar button (no custom UI); duplicate status items workaround needed; `openSettings` broken on macOS 26 Tahoe [27]. The `orchetect/MenuBarExtraAccess` package exists specifically to paper over these gaps [26]. Multiple shipping apps (per Tsai's blog roundup) drop to NSStatusItem for serious cases [27].

**Verdict: CONFIRMED.**

### Claim 5.3 — MenuBarExtra is the Apple-recommended path for new menu-bar apps in 2026

**What the web says.** Apple's official docs still position it as the path forward, and a Tahoe-targeted demo project (sjhooper/TahoeMenuDemo) presents it as the modern reference [29]. But the developer community's pragmatic recommendation in 2025-2026 leans toward NSStatusItem for anything non-trivial. There is no explicit "Apple recommends MenuBarExtra" statement; it's the only SwiftUI-native option, which is different from "recommended".

**Verdict: PARTIALLY CONFIRMED, see notes.** "Apple's SwiftUI-native option" — yes. "Apple's actively recommended path" — implied, not stated. For Stimmgabel's complexity level (icon state, audio metering, lazy-activation toggle), starting with MenuBarExtra and being prepared to drop to NSStatusItem is the right hedge.

### Claim 6 — Audio Server Plugin ↔ host app IPC via Mach service

**What the web says.** Apple Technical Q&A QA1811 documents the `AudioServerPlugIn_MachServices` Info.plist key explicitly for plug-in → other-process communication [30]. Background Music project (kyleneideck/BackgroundMusic) has a working XPC helper between BGMDriver (the AudioServerPlugIn) and BGMApp [31]. libASPL (gavv) is a C++17 library specifically for building these plugins [32]. The plug-in process is sandboxed and may only read its bundle plus system frameworks — XPC/Mach is how it talks out.

**Latency claim** (microseconds, fine for voice not music): I found no primary source benchmarking XPC frame-push latency for audio. The general design pattern is: audio data goes via shared memory or ring buffer, control messages go via XPC. "Microseconds for voice but not music" is a reasonable engineering rule of thumb but not a sourced fact.

**Verdict: PARTIALLY CONFIRMED, see notes.** Mach-service IPC mechanism: CONFIRMED. Specific latency numbers: NO CLEAR EVIDENCE — measure on target hardware.

### Beyond the architect's claims — 2025-2026 landscape

- **Loopback's ARK migration (macOS 14.5+)** is the biggest signal: Rogue Amoeba moved off pure-AudioServerPlugIn capture as soon as Core Audio Taps was stable enough. The modern best-practice architecture is: Process Tap (capture) + aggregate device (mix tap + mic) + AudioServerPlugIn (publish the result as a virtual input device). This matches Stimmgabel's planned architecture. [18]
- **WWDC 2025 / macOS 26 Tahoe:** no new system-audio API displacing Process Taps. macOS 26.1 shipped further audio bug fixes [17]. The platform direction is "make Core Audio Taps work better", not "replace it".
- **No DriverKit blessing for virtual audio** is still Apple's position as of mid-2026 [24]. Don't expect this to change.
- **`coreaudiod` restart gotcha (14.4+):** documented above. Build the install/reload step around `killall coreaudiod`, not `launchctl kickstart -k`.
- **`com.apple.audio.coreaudiod` running ASPs in their own sandboxed process** [21] — means Stimmgabel's app and plug-in must communicate via Mach service / XPC, cannot share memory blindly, and must declare any Mach service names in the plug-in's Info.plist `AudioServerPlugIn_MachServices` key.

## Sources

1. [insidegui/AudioCap on GitHub](https://github.com/insidegui/AudioCap) — Apple-engineer-authored reference implementation of Core Audio Tap, targets macOS 14.4+. Active 2024-2025.
2. [Apple: Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps) — Apple official documentation page.
3. [Apple: CATapDescription](https://developer.apple.com/documentation/coreaudio/catapdescription) — class reference.
4. [sudara gist: Example Core Audio Tap API in macOS 14.2](https://gist.github.com/sudara/34f00efad69a7e8ceafa078ea0f76f6f) — community example explicitly dated to 14.2.
5. [Apple: AudioHardwareCreateProcessTap](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:)) — function reference.
6. [pasrom/meeting-transcriber Issue #79: CATapDescription Microsoft Teams capture](https://github.com/pasrom/meeting-transcriber/issues/79) — real-world bug report showing known reliability quirks.
7. [Kevin M. Cox: Changes to launchctl kickstart in macOS 14.4 (Mar 2024)](https://www.kevinmcox.com/2024/03/changes-to-launchctl-kickstart-in-macos-14-4/) — primary source on the kickstart -k restriction.
8. [Apple Developer Forums: Where to install AudioServerPlugIn](https://developer.apple.com/forums/thread/130985) — Apple staff response confirming `/Library/Audio/Plug-Ins/HAL` only.
9. [makeusabrew/audiotee on GitHub](https://github.com/makeusabrew/audiotee) — CLI tool, README declares macOS 14.2+ requirement.
10. [Apple Developer Forums: Is it possible to get only audio from ScreenCaptureKit?](https://developer.apple.com/forums/thread/718279) — confirms SCK requires a screen target even for audio capture.
11. [Screenify Studio: macOS Screen Recording Permissions guide (Apr 2026)](https://www.screenify.studio/blog/2026-04-23-macos-screen-recording-permissions) — TCC behavior details for SCK.
12. [Rogue Amoeba: Update to macOS 15.1 for helpful audio bug fixes (Oct 2024)](https://weblog.rogueamoeba.com/2024/10/29/update-to-macos-15-1-for-helpful-audio-bug-fixes/) — Rogue Amoeba's audio bug log for 15.1.
13. [theevilbit blog: Beyond the good ol' LaunchAgents - 13 - Audio Plugins](https://theevilbit.github.io/beyond/beyond_0013/) — security researcher's writeup of HAL plugin loading by coreaudiod.
14. [creavit.studio: ScreenCaptureKit audio and microphone recording guide](https://creavit.studio/blog/screencapturekit-audio-recording-mac-guide) — practical SCK guide; corroborates audio-not-truly-isolated.
15. [Recall.ai: How to access system audio on macOS](https://www.recall.ai/blog/how-to-access-to-system-audio) — vendor blog (flag: marketing context) comparing approaches; useful for landscape but biased toward "use our SDK".
16. [ExistentialAudio/BlackHole on GitHub](https://github.com/ExistentialAudio/BlackHole) — reference open-source AudioServerPlugIn installer, installs to `/Library/Audio/Plug-Ins/HAL`.
17. [Rogue Amoeba: macOS 26 (Tahoe) includes important audio-related bug fixes (Nov 2025)](https://weblog.rogueamoeba.com/2025/11/04/macos-26-tahoe-includes-important-audio-related-bug-fixes/) — Rogue Amoeba's bug log for Tahoe 26.0/26.1.
18. [Rogue Amoeba: Details on Loopback's audio handling on macOS 14 and higher](https://rogueamoeba.com/support/knowledgebase/?showArticle=Misc-ARK-Plugin-Audio-Capture-Details&product=Loopback) — Loopback migrated to ARK on 14.5+; "no need to adjust your Mac's security settings".
19. [Moonbase: Code signing audio plugins in 2025, a round-up](https://moonbase.sh/articles/code-signing-audio-plugins-in-2025-a-round-up/) — audio-plugin signing landscape (2025).
20. [Apple Developer Forums: How do I properly code sign an Audio Server PlugIn?](https://developer.apple.com/forums/thread/676781) — Apple DTS (Quinn) on dev vs distribution signing.
21. [Apple Developer Forums: AudioServer plugin as System Extension](https://developer.apple.com/forums/thread/653571) — notes that ASP "runs in its own process" on current macOS.
22. [JUCE forum: How to start with signing audio plugins?](https://forum.juce.com/t/how-to-start-with-signing-audio-plugins/44972) — community confirmation that signing is required in practice.
23. [Rogue Amoeba Loopback product page (Audio Routing Kit)](https://rogueamoeba.com/loopback/) — vendor marketing (flag: marketing) noting ARK requirement on 14.5+.
24. [Apple Developer Forums: Entitlements for a virtual audio device](https://developer.apple.com/forums/thread/736357) — Apple's explicit "we will not grant DriverKit entitlements for virtual audio drivers".
25. [Apple: MenuBarExtra documentation](https://developer.apple.com/documentation/swiftui/menubarextra) — availability since macOS 13.
26. [orchetect/MenuBarExtraAccess](https://github.com/orchetect/MenuBarExtraAccess) — third-party workaround library; its existence is itself evidence of the API gaps.
27. [Peter Steinberger: Showing Settings from macOS Menu Bar Items - A 5-Hour Journey (2025)](https://steipete.me/posts/2025/showing-settings-from-macos-menu-bar-items) — recent (2025) developer report on MenuBarExtra issues incl. Tahoe regression.
28. [feedback-assistant: FB13683957 MenuBarExtra rerender issue](https://github.com/feedback-assistant/reports/issues/477) — open Apple-feedback issue.
29. [sjhooper/TahoeMenuDemo](https://github.com/sjhooper/TahoeMenuDemo) — modern Tahoe menu-bar reference implementation using MenuBarExtra.
30. [Apple Technical Q&A QA1811: AudioServerPlugIn_MachServices plist Key](https://developer.apple.com/library/archive/qa/qa1811/_index.html) — Apple's primary documentation of plug-in-to-host Mach service IPC.
31. [kyleneideck/BackgroundMusic: XPC helper between driver and app (commit)](https://github.com/kyleneideck/BackgroundMusic/commit/33b6b1711549f2a039ded3250d5df21ab6b6ebd3) — open-source reference of XPC bridge.
32. [gavv/libASPL](https://github.com/gavv/libASPL) — C++17 library for building AudioServerPlugIns.

## Open questions

- **Does `AudioHardwareCreateProcessTap` actually succeed inside the macOS App Sandbox?** No primary source confirms or denies. Test with a minimal sandboxed SwiftUI app on macOS 14.4 + 15.x + 26.1.
- **Does `~/Library/Audio/Plug-Ins/HAL/<bundle>.driver` get loaded by `coreaudiod` at all?** No documentation says yes. Try empirically before committing the v1 "unsigned, no admin" plan.
- **What is the actual XPC frame-push latency Stimmgabel will see on M-series and Intel?** Architect's "microseconds" is plausible but unmeasured.
- **Does an ad-hoc-signed (developer team only, no Developer ID) AudioServerPlugIn load on a clean macOS 26.1 install with SIP enabled?** Sources conflict; needs test.
- **Krisp's exact virtual-mic mechanism** is not directly verified (the architect named it as a peer; I could not find a primary source confirming AudioServerPlugIn).
