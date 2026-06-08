---
topic: CoreAudio aggregate device combining CATapDescription (process tap) + microphone sub-device on macOS 14+/26
date: 2026-06-08
requested_by: architect
related_tasks: [audio-engine-003, audio-engine-005, infrastructure-009]
---

# Research: CoreAudio Aggregate Device — Tap + Microphone Sub-device

## Question

How to correctly include a microphone input device as a sub-device in a CoreAudio aggregate
device that also contains a CATapDescription (Process Tap) on macOS 14+/26, covering:
channel layout in the IOProc callback, required dictionary keys, clock source selection,
TCC/permissions, practical examples, and known macOS 26 gotchas.

---

## Summary

- **Channel layout**: Sub-devices are concatenated in `kAudioAggregateDeviceSubDeviceListKey`
  array order. Tap sub-device listed first → its 2 channels appear as buffers 0–1; microphone
  listed second → its 1 channel appears as buffer 2 (or a separate `mBuffers[1]` entry in the
  non-interleaved ABL). There is no official Apple documentation explicitly describing this order
  for the tap-plus-mic case; it is inferred from the general HAL aggregate channel concatenation
  rule plus Audio MIDI Setup drag-to-reorder behaviour. **Must be verified empirically with
  `os_log` of the ABL at runtime.**
- **Dictionary keys**: Add the microphone UID as a second entry in
  `kAudioAggregateDeviceSubDeviceListKey`. Set `kAudioAggregateDeviceMainSubDeviceKey` to the
  microphone UID (real hardware clock). The tap entry stays in `kAudioAggregateDeviceTapListKey`
  unchanged. `kAudioAggregateDeviceTapAutoStartKey` is still needed.
- **Clock source**: The microphone (real hardware device) should be the master clock. The tap is
  a software source that has no independent clock; it follows whatever device drives the
  aggregate. Setting the mic as master avoids sample-rate negotiation deadlocks.
- **Permissions**: Both `NSAudioCaptureUsageDescription` (for the process tap) AND
  `NSMicrophoneUsageDescription` (for the mic sub-device) are required, plus the hardened-runtime
  entitlement `com.apple.security.device.audio-input`. Confirmed by multiple sources and by
  Maven.de's direct experience trying to avoid the mic permission when input streams were present.
- **No known Apple sample code** demonstrates the tap-plus-mic combination. All published examples
  (AudioCap, sudara gist, SoundPusher) use only the tap. The combination is novel territory with
  no vetted reference implementation found.
- **macOS 26 has significant CoreAudio instability**: audio stack degradation over time (unrelated
  to taps), zero-buffer delivery from process taps after extended sessions, and the pre-existing
  IOWorkLoop ETIMEDOUT when starting two independent devices. A single-aggregate approach
  sidesteps the two-device start race but does not eliminate the zero-buffer bug.

---

## Findings

### 1. Channel layout in `inInputData` AudioBufferList

No Apple documentation explicitly maps sub-device list order to AudioBufferList slot order for
aggregate devices containing both a tap and a microphone. However, the CoreAudio HAL treats an
aggregate device's input stream as the ordered concatenation of its sub-devices' input channels [1].
The Audio MIDI Setup user interface shows sub-devices side-by-side and notes that dragging a device
left gives it lower channel numbers [2]. This matches how all multi-device aggregates behave:
sub-devices are concatenated in list order.

Applied to tap + mic:

- **Sub-device list order**: `[tapSubDevice, micSubDevice]`
- **Tap sub-device** (stereo, 2 channels): CoreAudio presents it as a non-interleaved ABL with
  one buffer per channel (or one interleaved buffer with 2 channels — the actual packing depends
  on the aggregate's negotiated stream format, which in practice for a global tap is 2-channel
  interleaved). These appear as `inInputData->mBuffers[0]` (and possibly `mBuffers[1]` in
  non-interleaved mode).
- **Microphone sub-device** (mono, 1 channel): Its channel follows after the tap's channels, in
  the next buffer slot (`mBuffers[1]` if tap is interleaved, or `mBuffers[2]` if tap is
  non-interleaved).

**Critical caveat**: the tap sub-device (`kAudioSubDeviceUIDKey` pointing to the tap UID) and the
tap list entry (`kAudioSubTapUIDKey`) are separate things. The sub-device list slot for the tap
defines where its channels land in the ABL; the tap list entry tells the aggregate to activate the
tap. Both must be present for the tap to deliver audio [3][4].

The existing `SystemAudioAdapter` logs `IOProc format: nBufs=... nChPerBuf=...` on first callback.
The safest implementation approach is to log the full ABL structure from the first IOProc call and
use `kAudioAggregateDevicePropertyFullSubDeviceList` to map UID → channel offset at setup time.

There is one known channel-count artefact: if the system output device has more than 2 output
channels (e.g., a 4-channel interface), the tap's buffer volume is halved relative to expected
levels [3]. This suggests the tap sub-device may present more channels than just 2 in that
scenario. For the common case of a 2-channel output device the tap is reliably stereo.

### 2. Aggregate device dictionary keys

The minimal working dictionary for tap-only (current implementation) is [3][4][5]:

```swift
[
  kAudioAggregateDeviceNameKey:        "...",
  kAudioAggregateDeviceUIDKey:         "...",
  kAudioAggregateDeviceSubDeviceListKey: [ [kAudioSubDeviceUIDKey: tapUID] ],
  kAudioAggregateDeviceTapListKey:     [ [kAudioSubTapUIDKey: tapUID] ],
  kAudioAggregateDeviceTapAutoStartKey: true,
  kAudioAggregateDeviceIsPrivateKey:   true,
]
```

To add a microphone sub-device, extend the sub-device list and add the master clock key:

```swift
let micUID = /* read kAudioDevicePropertyDeviceUID from default input device */

[
  kAudioAggregateDeviceNameKey:        "Stimmgabel Capture",
  kAudioAggregateDeviceUIDKey:         "com.innoq.stimmgabel.captureAggregate",
  kAudioAggregateDeviceSubDeviceListKey: [
    [kAudioSubDeviceUIDKey: tapUID],          // index 0 → channels 0..N-1 (tap)
    [kAudioSubDeviceUIDKey: micUID,           // index 1 → channels N..N+M-1 (mic)
     kAudioSubDeviceDriftCompensationKey: true]
  ],
  kAudioAggregateDeviceTapListKey:     [ [kAudioSubTapUIDKey: tapUID] ],
  kAudioAggregateDeviceTapAutoStartKey: true,
  kAudioAggregateDeviceIsPrivateKey:   true,
  kAudioAggregateDeviceMainSubDeviceKey: micUID,  // mic is the master clock
]
```

**Key-by-key rationale**:

- `kAudioAggregateDeviceSubDeviceListKey`: lists both sub-devices. This is what determines
  channel slots and enables the mic's input stream to appear in `inInputData`. Tap-only examples
  omit the mic entry entirely [3][4]; adding it here is the change that enables the combined flow.
- `kAudioAggregateDeviceTapListKey`: unchanged — still points to the tap UID via
  `kAudioSubTapUIDKey`. This key activates the tap; the sub-device list entry separately assigns
  it a channel slot [5].
- `kAudioAggregateDeviceMainSubDeviceKey`: specifies the master clock source. Should be the mic
  UID (a real hardware device with a physical clock). If omitted, CoreAudio picks one heuristically;
  specifying it explicitly avoids ambiguity [6].
- `kAudioSubDeviceDriftCompensationKey: true` on the mic (the non-clock device): enables sample-
  rate drift correction between the mic and the aggregate clock. The tap, being a software source,
  does not need drift compensation [3].
- `kAudioAggregateDeviceTapAutoStartKey: true`: still required; without it the tap does not start
  and the tap channels deliver silence [3][4].

**Documentation bug in Apple sample code**: The Apple documentation for
`kAudioAggregateDevicePropertyTapList` contains an error where `tapID` is used as the target
`AudioObjectID` for `AudioObjectSetPropertyData` instead of `aggregateDeviceID`. The property
belongs to the aggregate device, not the tap [7].

### 3. Clock source

The microphone should be the master clock (`kAudioAggregateDeviceMainSubDeviceKey = micUID`).

Rationale:
- The process tap has no independent hardware clock — it is a software intercept of another
  device's output stream. Making the tap the master clock effectively delegates clock authority to
  an ephemeral software object, which is not a stable timing reference.
- The microphone is a real hardware device with a physical clock. Setting it as master means all
  other sub-devices (the tap in this case) synchronise to it.
- Latency: the drift compensation on the non-master sub-device adds a few milliseconds of
  buffering. Since both tap and mic feed a downstream mixer (not a real-time performance monitor),
  this is acceptable.
- The general rule from Apple and the BlackHole community: "Built-in Output or Built-in Microphone
  must be the Clock Source device" in aggregates that mix hardware and virtual/loopback devices [8].
  A process tap is analogous to a virtual device in this respect.

If the built-in microphone is not available (e.g., external USB mic), the same logic applies —
use the real hardware device as master.

### 4. TCC / Permissions

Two distinct privacy gates apply when combining a tap and a microphone sub-device:

**Process Tap (system audio capture)**:
- Requires `NSAudioCaptureUsageDescription` in Info.plist (separate key from
  `NSMicrophoneUsageDescription`, must be added manually — not in Xcode's dropdown) [9].
- Produces a purple dot indicator in the macOS menu bar (less intrusive than the orange mic dot).
- There is no public API to check TCC authorization status programmatically; denied access results
  in silence with no error [6].

**Microphone input sub-device**:
- Requires `NSMicrophoneUsageDescription` in Info.plist [10].
- Requires the hardened-runtime entitlement `com.apple.security.device.audio-input` [11].
- Produces the orange dot indicator in the macOS menu bar.
- Maven.de's SoundPusher explicitly removed all input/loopback streams from its virtual audio
  device specifically to avoid the microphone TCC gate [6]. This confirms that adding a real
  microphone as a sub-device in a tap-containing aggregate triggers the microphone permission
  prompt.

**Summary**: both Info.plist keys and the `audio-input` entitlement are required. The app must
handle the case where microphone permission is denied (graceful degradation: fall back to tap-only).

**macOS Sandbox note**: `AudioHardwareCreateProcessTap` is unconfirmed inside the App Sandbox.
The current project runs unsandboxed. Adding a mic sub-device does not change this constraint.

### 5. Practical examples

No public example demonstrates the exact tap + mic aggregate combination. The closest references:

- **AudioCap (insidegui)** [12]: tap-only aggregate. Shows the basic dictionary structure and
  IOProc callback pattern used in the current `SystemAudioAdapter`. Does not add a microphone
  sub-device.
- **sudara gist** [3]: tap-only, Objective-C. Documents the channel-count volume bug for
  multi-channel output devices.
- **SoundPusher / Maven.de** [6]: explicitly removed mic input to avoid the permission. Confirms
  that if a tapped device has input streams, microphone TCC is required regardless.
- **larussverris gist** [13]: tap-free aggregate with default input + default output sub-devices.
  Shows `kAudioSubDeviceDriftCompensationKey` usage and the two-device sub-device list pattern
  that is directly relevant.
- **sbooth/CAAudioHardware** [14]: Swift wrapper. Exposes `tapList`, `subTapList`,
  `fullSubdeviceList`, `activeSubdeviceList`, and `mainSubdevice`. Shows that main/master
  sub-device is queried via `kAudioAggregateDevicePropertyMainSubDevice` (deprecated name was
  `masterSubdevice`; new name is `mainSubdevice` since macOS 12).

There are no known Rogue Amoeba open-source examples (Loopback is commercial and closed-source).
No WWDC session specifically on tap + mic aggregates was found.

### 6. Known issues on macOS 14/15/26

**Zero-buffer delivery (macOS 26.5 Beta, observed 2026-05)**: `AudioHardwareCreateProcessTap`
intermittently delivers all-zero PCM samples after extended sessions (minutes to hours), while
the IOProc callback continues firing normally and system audio remains audible. Full teardown and
recreation of both the tap and aggregate device restores real data. Root cause unknown; no Apple
response as of the thread date [7-b].

**macOS Tahoe (26.x) audio stack degradation**: A separate, progressive degradation of system
audio quality (volume drop, muffled output) has been observed on macOS 26.3 affecting all audio
clients. It requires killing all CoreAudio-using applications plus restarting all audio daemons
(`coreaudiod`, `audiomxd`, `audioclocksyncd`, etc.). This is a system-level regression unrelated
to taps but affects any audio application on macOS 26 [15].

**IOWorkLoop ETIMEDOUT (0x3C) on concurrent AudioDeviceStart**: The original problem motivating
this research. Starting two independent `AudioDeviceID`s concurrently hits a race in coreaudiod's
IOWorkLoop. A single-aggregate approach eliminates this by reducing to one `AudioDeviceStart`
call, which is the correct architectural fix regardless of this research [existing project context].

**Level attenuation bug**: When the system output device has N > 2 stereo pairs, the tap delivers
audio at 1/N the expected amplitude. This is a known CoreAudio bug reported in the sudara gist [3].
It is unrelated to the mic sub-device addition.

**Sample rate mismatch**: If the microphone runs at a different native rate than the system output
device (e.g., USB mic at 44.1 kHz, speakers at 48 kHz), the aggregate must negotiate a common
rate. Setting `kAudioAggregateDeviceMainSubDeviceKey` to the mic device and enabling drift
compensation on the tap sub-device handles this, but the negotiated rate may change from what the
current `SystemAudioAdapter` expects. The existing code already queries the actual rate after
device creation; this needs to be extended to account for multi-stream formats (tap channels vs.
mic channels may be at different positions in the ABL).

**macOS 14.2 vs 14.4 tap stability**: The tap API was introduced in macOS 14.2 but exhibited
reliability issues; 14.4 is the stated stability floor for `AudioHardwareCreateProcessTap` [12].
This is unchanged regardless of whether a mic sub-device is added.

---

## Sources

1. [Core Audio Essentials — Apple Developer Library (archived)](https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/CoreAudioOverview/CoreAudioEssentials/CoreAudioEssentials.html) — Aggregate device channel concatenation in the HAL; archived circa 2015 but the aggregate model is unchanged.
2. [Create an Aggregate Device — Apple Support](https://support.apple.com/en-us/102171) — User-facing guide; confirms sub-device order determines channel numbers (drag left = lower numbers).
3. [CoreAudio Tap API example (Objective-C) — sudara gist](https://gist.github.com/sudara/34f00efad69a7e8ceafa078ea0f76f6f) — Tap-only aggregate dictionary keys, channel-count volume bug, 2024.
4. [AudioCap README — insidegui/AudioCap](https://github.com/insidegui/AudioCap/blob/main/README.md) — `NSAudioCaptureUsageDescription` requirement, step-by-step IOProc setup, macOS 14.4+.
5. [kAudioAggregateDeviceTapListKey — Apple Developer Documentation](https://developer.apple.com/documentation/coreaudio/kaudioaggregatedevicetaplistkey) — Authoritative key name and presence in aggregate dict.
6. [CoreAudio Taps for Dummies — maven.de (April 2025)](https://www.maven.de/2025/04/coreaudio-taps-for-dummies/) — Microphone permission gate when input streams present, tap authorization behaviour, no programmatic status query.
7. [Potential Documentation Error in kAudioAggregateDevicePropertyTapList — Apple Developer Forums (Sep 2025)](https://developer.apple.com/forums/thread/798941) — Apple sample code bug: tapID used instead of aggregateDeviceID.
7-b. [AudioHardwareCreateProcessTap delivers zero-filled buffers — Apple Developer Forums (May 2026)](https://developer.apple.com/forums/thread/825780) — Zero-buffer bug on macOS 26.5 Beta; workaround is full teardown + recreate.
8. [Aggregate Device — BlackHole Wiki](https://github.com/ExistentialAudio/BlackHole/wiki/Aggregate-Device) — Built-in device as clock source recommendation; drift correction on all non-master sub-devices.
9. [NSAudioCaptureUsageDescription — Apple Developer Documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription) — Required Info.plist key for system audio tap permission prompt.
10. [NSMicrophoneUsageDescription — Apple Developer Documentation](https://developer.apple.com/documentation/BundleResources/Information-Property-List/NSMicrophoneUsageDescription) — Required Info.plist key for microphone access.
11. [Audio Input Entitlement — Apple Developer Documentation](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.device.audio-input) — `com.apple.security.device.audio-input` hardened-runtime entitlement for microphone + audio input.
12. [AudioCap — insidegui/AudioCap on GitHub](https://github.com/insidegui/AudioCap) — De-facto reference implementation for tap-only aggregate devices, macOS 14.4+.
13. [Creating an aggregate device in Objective-C — larussverris gist](https://gist.github.com/larussverris/5387819a3a7337937084730a86cee073) — Two-sub-device aggregate (input + output); drift compensation; no tap.
14. [AudioAggregateDevice.swift — sbooth/CAAudioHardware](https://github.com/sbooth/CAAudioHardware/blob/main/Sources/CAAudioHardware/AudioAggregateDevice.swift) — Swift API wrapper; exposes mainSubdevice, tapList, subTapList.
15. [macOS Tahoe audio degradation workaround — metrovoc gist (2026)](https://gist.github.com/metrovoc/0b5e3590c6069cf99b01559863bc2ce4) — Tahoe 26.x progressive audio stack corruption; requires killing all CoreAudio clients.

---

## Open questions

1. **Actual ABL layout for tap + mono mic**: No source explicitly confirms `mBuffers[0]` = tap-L,
   `mBuffers[1]` = tap-R (or interleaved tap in `mBuffers[0]`), `mBuffers[1 or 2]` = mic. Must
   verify empirically by logging `mNumberBuffers`, `mNumberChannels`, and `mDataByteSize` per
   buffer on first IOProc invocation.

2. **`kAudioAggregateDeviceTapAutoStartKey` with mic sub-device**: All examples that use this key
   are tap-only. It is unknown whether adding a mic sub-device changes when or whether the key
   is needed. Low risk; keep it `true`.

3. **Sample rate negotiation**: If the mic's native rate differs from the tap's output rate, the
   aggregate will settle on a common rate. The negotiated rate might not be 48 kHz. The existing
   post-creation rate query must continue to drive the AVAudioConverter setup.

4. **Zero-buffer bug mitigation**: The zero-buffer delivery bug (finding 6) has no upstream fix
   as of June 2026. A watchdog that detects consecutive zero-sample callbacks and performs a full
   teardown + rebuild would be required for production resilience.

5. **`kAudioAggregateDeviceIsPrivateKey`**: All tap examples set this to `true` (device invisible
   in Audio MIDI Setup). Whether this interacts with the mic sub-device's TCC prompt is unknown.
   The mic TCC prompt depends on the process entitlement and Info.plist key, not device visibility,
   so it likely has no effect.
