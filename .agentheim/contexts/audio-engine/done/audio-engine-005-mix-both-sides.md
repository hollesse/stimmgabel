---
id: audio-engine-005
title: Mix — combine mic side and system-audio side into a single float32 stereo buffer
status: done
type: feature
context: audio-engine
created: 2026-06-05
completed: 2026-06-05
commit: 7468c6d
depends_on: [audio-engine-003, audio-engine-004]
blocks: [audio-engine-006]
tags: [mix, coreaudio, dsp, mute, float32, stereo]
related_adrs: [0006, 0010, 0009]
related_research: []
prior_art: [audio-engine-001, audio-engine-002]
---

## Why

The engine's purpose is a single mixed stream: mic side + system-audio side. ADR 0010 decided that
muting a side means zeroing its contribution in the mix — not stopping its upstream capture. The mix
step is where both sides converge and where the mute booleans are applied.

## What

Implement the mix step inside `AudioPipeline` (or a dedicated `Mixer` type) that:

1. **Receives buffers from both sides** — `MicAdapter` and `SystemAudioAdapter` each deliver
   float32 stereo buffers at 48 kHz per render cycle (or as fast as they produce). The mix step
   accepts these asynchronously (both adapters may deliver at slightly different real-time
   cadences).

2. **Applies per-side mute** — if `micMuted == true`, treat the mic buffer as all-zeros for this
   cycle. If `systemAudioMuted == true`, treat the system-audio buffer as all-zeros. Per ADR 0010,
   the upstream adapters are NOT stopped on mute — they continue running. Only the contribution to
   the mix is silenced.

3. **Sums the two sides** — add corresponding float32 samples from both buffers. No normalization
   or gain adjustment in v1; the result may clip if both sides are at 0 dBFS simultaneously
   (acceptable, deferred to v2). Channel count and sample rate are identical on both inputs (both
   adapters convert internally to the target format).

4. **Produces the output buffer** — a `[Float]` array (or `AVAudioPCMBuffer`) of `frameCount`
   interleaved stereo frames at 48 kHz, ready to be written into the driver's ring buffer by
   the output adapter (audio-engine-006).

5. **Thread safety** — the mix step is driven by the driver's DoIOOperation cadence (via the
   output adapter), not by the adapters. The adapters deliver into a small per-side staging buffer
   (e.g. a lock-free ring); the mix step drains those buffers each cycle.

## Acceptance criteria

- [ ] With both adapters delivering known sine tones (in tests: fakes), the mixer output equals
      their sum at each sample position (Tier-1 unit test).
- [ ] With mic muted, the output equals the system-audio buffer only; mic samples do not appear
      (Tier-1 unit test).
- [ ] With system-audio muted, the output equals the mic buffer only (Tier-1 unit test).
- [ ] With both muted, the output is all-zeros (Tier-1 unit test).
- [ ] The mix step does not block the audio thread if one side has not yet delivered a buffer
      (emits silence for that side in the current cycle).
- [ ] Existing Tier-1 tests continue to pass.

## Notes

- The walking skeleton's `AudioPipeline` already has a state machine and 10 Tier-1 tests. This
  task extends it; do not replace or break the existing structure.
- The per-side staging ring buffer size should match the driver's ring buffer size (4096 frames)
  so the two rings stay in sync.
- Sample addition: `output[i] = mic[i] + sysaudio[i]`. No soft-clipping in v1.
- Future v2 concern: per-side gain (volume faders). Preserve a single multiplication slot
  (`gain * sample`) in the add path so v2 can wire a gain value without restructuring.
- ADR 0010 note: the v1 architecture "preserves per-side adapter start/stop lifecycles so v2
  can suspend-on-mute as a one-seam change." Keep `start()` / `stop()` as the activation path
  (driven by lazy activation, not by mute), so mute and activation remain orthogonal.

## Outcome

Introduced `Mixer` (`Sources/AudioEngine/Mixer.swift`) with:
- Two `StagingBuffer` objects (one per side), each protected by `os_unfair_lock`, storing the most recent delivered buffer as interleaved float32 samples.
- `receiveMic(_:)` / `receiveSysAudio(_:)` called from the adapter's render thread.
- `mix(frameCount:micMuted:systemAudioMuted:) -> [Float]` producing `frameCount * 2` interleaved samples by draining both staging buffers and summing: `micGain * mic[i] + sysAudioGain * sysaudio[i]`. Absent buffers treated as silence; muted sides contribute zero. `micGain` / `sysAudioGain` are unity-defaulted slots for v2 gain faders.

`AudioPipeline` updated:
- Owns a `Mixer` instance; wires both adapter `onBuffer` closures to `Mixer.receive*` in `init`.
- `onSystemAudioBuffer` / `onMicBuffer` pass-through properties preserved; their `didSet` overlays the staging-buffer write with the external handler.
- New `mix(frameCount: Int) -> [Float]` public method reads mute state on the serial queue and delegates to `Mixer.mix`.

5 new Tier-1 unit tests added (`test_mix_bothSides_outputIsSum`, `test_mix_micMuted_outputIsSystemAudioOnly`, `test_mix_systemAudioMuted_outputIsMicOnly`, `test_mix_bothMuted_outputIsAllZeros`, `test_mix_oneSideAbsent_treatsAsSilence`). All 34 tests pass.
