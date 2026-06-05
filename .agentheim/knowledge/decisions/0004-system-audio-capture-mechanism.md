---
id: 0004
title: Capture system audio via the CoreAudio Process Tap API; minimum macOS 14.4
scope: global
status: accepted
date: 2026-06-05
supersedes: []
superseded_by: []
related_tasks: [infrastructure-002]
related_research: [macos-audio-platform-2026-06-05]
---

# ADR 0004: Capture system audio via the CoreAudio Process Tap API; minimum macOS 14.4

## Context

Stimmgabel must capture *all* audio currently playing on the Mac (Zoom remote audio, browser, Spotify, notifications, all at once) and feed it into the mix. The vision explicitly rules out per-app selection for v1 — "all of it, mixed" is the contract — and the mic-indicator promise (the macOS mic indicator only lights up while a downstream consumer is actively reading) forbids any always-on capture path that would hold the mic open.

Four mechanisms are viable on modern macOS:

1. **CoreAudio Process Tap API** (`AudioHardwareCreateProcessTap` / `kAudioObjectClassProcessTap`, introduced in macOS 14.2 and hardened in 14.4). Apple-blessed modern path for capturing audio from one or more processes, or from "all output". Requires `NSAudioCaptureUsageDescription` (TCC mic permission, same prompt the user already grants for the real mic). No kernel or HAL extension required. Can be created and destroyed at will from a normal app process.
2. **ScreenCaptureKit system-audio-only capture** (`SCStreamConfiguration.capturesAudio`, available since macOS 13, audio-only mode in 14.2). Captures system audio without screen frames, but the framework still belongs to the screen-recording subsystem and triggers the **screen-recording TCC prompt** (`NSScreenCaptureUsageDescription`).
3. **Audio Server Plugin acting as a loopback driver** (the BlackHole pattern). Captures whatever macOS routes through the virtual device. Requires the user to manually set the virtual device as the system default output — exactly the configuration Stimmgabel is built to eliminate.
4. **Bundle / require BlackHole.** Same as (3) but using someone else's driver.

## Decision

Use the **CoreAudio Process Tap API**. Specifically:

- At consumer-attach time (lazy activation), the audio-engine creates a `CATapDescription` configured as a system-wide global tap — empty process list passed to `initStereoGlobalTapButExcludeProcesses([])` (or the mono variant) — and wraps it in an aggregate device that lists the tap under the `kAudioAggregateDeviceTapListKey`. The aggregate device is then the read-side of the system-audio source.
- The engine listens on `kAudioHardwarePropertyDefaultOutputDevice`; when it fires, the engine tears down the current aggregate device + tap and re-creates the pair bound to the new default output.
- At consumer-detach time, both the aggregate device and the tap are destroyed. No samples are read while idle. The mic indicator does not glow.
- **Minimum macOS version: 14.4 (Sonoma).** Apple's own reference sample (`insidegui/AudioCap`) and the current Apple developer documentation target 14.4+. The API symbols ship in 14.2 but Apple's own production-grade reference and active community projects (`AudioTee` aside) standardise on 14.4 — treat that as the supported floor.

## Consequences

### Positive
- One prompt, the right prompt: TCC microphone permission, which the user already understands for an audio tool.
- No kernel extension, no HAL extension, no `kext`-equivalent entitlements.
- Lazy activation is honest: when no consumer is reading, no tap exists, no samples flow, the mic indicator stays off.
- Default-output changes (HDMI plugged in, AirPods connected) rebind the system-audio side transparently — the tap is just torn down and re-created.
- Stimmgabel does not become a system default output; the user never has to change a setting in System Settings → Sound.

### Negative
- **Hard minimum of macOS 14.4.** Anyone on Ventura or earlier Sonoma point releases cannot run Stimmgabel. The primary user is current; the secondary INNOQ-team audience must be confirmed before this number is locked.
- The Process Tap API is still relatively young (2024–2026). Edge cases (system audio routed to a Bluetooth device that disconnects mid-tap, audio-only Spatial Audio sessions) may surface bugs we have to work around. macOS 26.1 (Tahoe) shipped further Process-Tap-adjacent bug fixes in late 2025 — the pipeline has visibly matured but bugs still ship per release.
- Capturing "all output" includes notification sounds and any other UI audio — for v1 this is acceptable (it's literally what the vision asks for) but a future per-app filter ADR will replace this mechanism's configuration, not the mechanism itself.
- **Sandbox compatibility is unverified.** No primary source confirms or denies that `AudioHardwareCreateProcessTap` works inside the macOS App Sandbox. Stimmgabel must either run unsandboxed (acceptable for v1) or confirm sandbox-compatibility empirically in the walking skeleton before deciding on entitlements.

### Neutral
- The published-language contract to the consumer (a normal CoreAudio input device, see ADR for virtual-mic publishing) is unaffected by this choice — the tap is purely an internal implementation detail.

## Alternatives considered

- **ScreenCaptureKit system-audio-only capture.** Rejected for two reasons. (1) Triggers the screen-recording TCC prompt — wrong prompt for an audio tool, will confuse the user and erode trust ("Why does this audio app want to record my screen?"). (2) **There is no real audio-only mode.** Developer reports and the official forum confirm SCK requires a screen capture session; even in "audio-only" usage you must start a screen session and discard the frames in the callback. The first reason alone is sufficient; the second makes the rejection even cleaner.
- **Audio Server Plugin as a loopback driver (BlackHole pattern).** Rejected. The user would have to manually set the virtual device as the macOS default output, which is precisely the brittle configuration step Stimmgabel is built to eliminate. Also breaks the "follows your system defaults" core promise — the *user's chosen* speakers/headphones would stop playing audio.
- **Bundle BlackHole.** Rejected. Same as above plus an additional kernel/HAL extension install (kext-adjacent UX even when it's an Audio Server Plugin), making the install story heavier than the thing it replaces.
- **AVAudioEngine taps on the default output node.** Rejected. AVAudioEngine cannot tap system-wide output, only its own engine graph.

## References
- `vision.md` — "Stimmgabel follows your system defaults" core promise; lazy-activation mic-indicator requirement
- `audio-engine/README.md` — open questions on system-audio capture mechanism
- `knowledge/research/macos-audio-platform-2026-06-05.md` — verified API timeline, aggregate-device wrapping pattern, sandbox open question, SCK no-audio-only mode finding
- Apple developer documentation: `AudioHardwareCreateProcessTap`, `kAudioObjectClassProcessTap`, `CATapDescription`, `kAudioAggregateDeviceTapListKey`
- `insidegui/AudioCap` — Apple-engineer-authored reference implementation, targets 14.4+
