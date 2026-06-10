---
id: audio-engine-007
title: Architectural reset — Phase 1/2 simplification and driver stabilisation
status: done
type: decision
context: audio-engine
created: 2026-06-08
completed: 2026-06-08
commit: b06e653
depends_on: []
blocks: []
tags: [architecture, simplification, driver, mic, refactor]
related_adrs: []
related_research: []
prior_art: [audio-engine-002, audio-engine-004, audio-engine-005, menubar-ui-001, menubar-ui-002]
---

## Why

After the initial implementation the virtual mic delivered silence to consumers
(Handy, Audacity). A long debugging session revealed multiple stacked problems
in the driver, the IPC layer, and the pipeline architecture. Rather than patching
each issue individually we did a focused architectural reset in two phases.

## What

### Phase 1 — System audio only, no mute, no render timer

The Mixer/StagingBuffer render-timer approach caused clock drift between the
software DispatchSource timer and the hardware IOProc, producing robotic
stuttering. Mute toggles (MutePreferences, setSideMute) were removed entirely
to reduce complexity. The pipeline was reduced to:

```
SystemAudioAdapter.IOProc → AudioPipeline.forward() → SHM → Driver
```

Key driver fixes in this phase:
- `ioMainBuffer` is a flat `float*` (mono device), not an `AudioBufferList*`
- `kChannelCount` reduced to 1 (mono) — eliminates ABL ambiguity with coreaudiod
- Sequential `gReadPos` consumer pointer in `DoIOOperation` (was latest-frame model)
  → each frame delivered exactly once; eliminates the "same 192 frames repeated
  2-3×" that caused robotic stuttering

### Phase 2 — Mic re-added via AVAudioEngine

MicAdapter was rewritten from direct HAL (`AudioDeviceCreateIOProcIDWithBlock` +
`AudioDeviceStart`) to `AVAudioEngine`. The HAL approach caused a macOS 26
`HALC_ProxyIOContext IOWorkLoop 0x3C (ETIMEDOUT)` deadlock when both the
SystemAudioAdapter Process Tap aggregate and the mic device were started
concurrently. AVAudioEngine avoids this by using a higher-level audio session
path.

AVAudioEngine is started lazily (on consumer-attach, in the background) so the
mic indicator only shows during active recording. System audio starts
synchronously first; mic joins ~1–2 s later via the `micStaging` FIFO.

A `micGain` parameter (default 3.0) compensates for the mic input level being
lower than the system audio tap output.

## Acceptance criteria

- [x] Virtual mic delivers clean system audio to Handy/Audacity
- [x] Mic audio is audible and mixed with system audio
- [x] No robotic stuttering (sequential gReadPos in driver)
- [x] No persistent mic indicator (AVAudioEngine stopped on consumer-detach)
- [x] 68/68 tests green, including VirtualMicE2ETests and PlaybackE2ETests

## Notes

Supersedes:
- **audio-engine-002** (mute architecture) — mute removed, deferred to Phase 3
- **audio-engine-004** (HAL IOProc mic) — replaced by AVAudioEngine
- **audio-engine-005** (Mixer class) — replaced by direct forwardMixed() in pipeline
- **menubar-ui-001** (mute persistence) — MutePreferences.swift deleted
- **menubar-ui-002** (mute toggles) — UI removed, deferred to Phase 3

Phase 3 will re-introduce mute toggles and a gain slider for the mic.
