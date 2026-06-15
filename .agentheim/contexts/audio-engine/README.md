# audio-engine

## Purpose
Capture the macOS default microphone + all system audio output, mix them into a single live audio stream, and publish that stream as a virtual input device that other apps can read. Track default-device changes on both sides and rebind transparently. Activate the upstream captures only while a consumer is reading.

## Classification
**core**

This is Stimmgabel's reason to exist. Everything in `menubar-ui` is here to expose this engine to a human; everything in `infrastructure` is here to ship this engine.

## Actors
- **macOS audio frameworks (CoreAudio / HAL / ScreenCaptureKit)** — the upstream source of mic samples and system-audio samples, and the registry that exposes the virtual mic to other apps. Stimmgabel is a conformist here; the contracts come from Apple.
- **Consumer apps** (Zoom, Handy, OBS, screen recorders, transcribers, …) — downstream readers of the virtual mic. They see Stimmgabel as a regular microphone. Stimmgabel does not know or care which app is consuming.
- **menubar-ui** — sibling context in the same process. Sends commands (mute / unmute per side) and reads state (consumer attached, current device names).

## Ubiquitous language

- **Sample / frame / buffer** — standard CoreAudio terms; one *frame* per channel per *sample* instant, gathered into a *buffer* per audio render cycle.
- **Sample rate / channel count** — properties of an audio stream. The mix has to reconcile mismatches between the mic side and the system-audio side.
- **Device** — a macOS audio device with an `AudioDeviceID`. Has a transport (built-in, USB, Bluetooth, virtual), a direction (input/output), and one or more streams.
- **Default input device / default output device** — the device macOS currently uses for system input/output. Stimmgabel tracks these; it does not let the user pin specific devices.
- **Mic side** — the half of the mix sourced from the current macOS default *input* device.
- **System-audio side** — the half of the mix sourced from *all* audio playing on the Mac (everything routed to the current default output, in aggregate, not per-app).
- **Mix** — the live combined audio stream emitted by the engine. Two mono/stereo inputs → one output stream.
- **Virtual mic** — the audio input device Stimmgabel publishes to macOS. Named "Stimmgabel". Has a fixed identity across launches.
- **Consumer** — a process that has opened the virtual mic for reading. Zero, one, or many simultaneously (the engine does not arbitrate).
- **Lazy activation** — the rule that the engine opens its upstream captures only while at least one consumer is reading. With zero consumers: no mic indicator, no CPU, no audio flowing.
- **Mute (per side)** — a boolean per side. A muted side contributes silence to the mix; the other side passes through unchanged. Mute does *not* stop the upstream capture (yet — performance optimisation later).
- **Default tracking** — the behaviour of re-binding the mic side or system-audio side to whatever macOS now considers the default input/output, without user action and without interrupting the consumer.
- **Default-device monitor** — a process-lifetime observer (`DefaultDeviceMonitor`) of the macOS default input + default output device *names*. Independent of capture state, so the UI can always show "which mic and which output Stimmgabel will use" — even when no consumer is attached and no adapter is running. Same HAL property-listener pattern as the per-side adapters (ADR 0006), but its job is UI data, not capture.

## Aggregates

Tactical modelling has not happened yet; these are placeholders for future `model` sessions.

- **AudioPipeline** — owns the upstream captures, the mix, and the virtual-mic publication; protects the invariant *"if any consumer is reading, upstream capture is running; otherwise it is not"*.
- **DeviceWatcher** — observes default-device changes; protects the invariant *"the mic side and system-audio side always reflect the current macOS defaults"*.

## Key events
- **VirtualMicConsumerAttached** — first consumer started reading; upstream captures should be opening.
- **VirtualMicConsumerDetached** — last consumer stopped reading; upstream captures should be tearing down.
- **DefaultInputDeviceChanged** — macOS reports a new default input; mic side must rebind.
- **DefaultOutputDeviceChanged** — macOS reports a new default output; system-audio side must rebind.

## Key commands
- **SetSideMute(side, on/off)** — issued by `menubar-ui`. Side is `mic` or `system-audio`.
- **PublishVirtualMic** — issued at app launch by `infrastructure`/the app shell.

## Relationships with other contexts
- **Partnership with menubar-ui** — small shared interface (commands above + a few observable states). See `context-map.md`.
- **Conformist to macOS audio frameworks** — no portable abstraction layer. See `context-map.md`.
- **Open host to consumer apps** — the published language is "a macOS audio input device".

## Open questions
- ~~Which exact mechanism publishes the virtual mic — Audio Server Plugin? A modern HAL extension? Something else?~~ Resolved by ADR 0005: **Audio Server Plugin**, installed system-domain at `/Library/Audio/Plug-Ins/HAL/`, ad-hoc signed, communicates with the app via Mach service / XPC.
- ~~How to capture *all* system audio in a way that survives default-output changes — ScreenCaptureKit vs. tap-based vs. virtual-loopback driver.~~ Resolved by ADR 0004: **CoreAudio Process Tap API** with empty-process-list `CATapDescription` wrapped in an aggregate device; rebind on `kAudioHardwarePropertyDefaultOutputDevice` change. macOS 14.4+.
- ~~Whether mute should also suspend the muted side's upstream capture (privacy-positive: no samples even read) or only zero it in the mix (simpler).~~ Resolved by ADR 0010: **v1 zeroes in the mix**; v1 architecture preserves per-side adapter `start()` / `stop()` lifecycles so v2 can suspend-on-mute as a one-seam change.
- ~~Sample-rate / channel-count reconciliation between the two sides — assume the engine resamples internally to a fixed target (48 kHz / float32 / stereo, per ADR 0006); confirm with first prototype.~~ `MicAdapter` uses `AudioConverterNew` + `AudioConverterFillComplexBuffer` to reconcile on the way in; `SystemAudioAdapter` reads natively at the mix target from the Process Tap aggregate.
- **Empirical (resolved by walking-skeleton `infrastructure-006`):** does `AudioHardwareCreateProcessTap` work inside the macOS App Sandbox? Currently no documentation says yes. The spike runs unsandboxed; sandbox compatibility is a follow-up question for the real-Process-Tap implementation (`audio-engine-003` implemented `SystemAudioAdapter` unsandboxed; a follow-up task should test sandbox behaviour empirically).

## Implementation status

| Component | Status | Notes |
|---|---|---|
| `DefaultDeviceMonitor` | done | Process-lifetime observer of default input/output device names; HAL property-listener pattern; feeds UI in idle state (audio-engine-008) |
| `UpstreamCaptureAdapter` (protocol) | done | Seam for Tier-1 testing (ADR 0009) |
| `SystemAudioAdapter` | done | Process Tap, rebinds on default-output change (ADR 0004) |
| `MicAdapter` | done | HAL IOProc on default input device, rebinds on default-input change, TCC prompt, AudioConverter for format reconciliation (ADR 0006) |
| `AudioPipeline` | done | Consumer-lifecycle, mute-flag management, `mix(frameCount:)` entry point (ADR 0010); delegates `currentMicDeviceName` / `currentSystemAudioDeviceName` to `DefaultDeviceMonitor` (audio-engine-008) |
| `Mixer` | done | Per-side staging buffers, sample-wise sum, per-side mute as zero, gain slots for v2 (audio-engine-005) |
| `DriverOutputAdapter` | done | XPC client to driver ring buffer; drives 512-frame render timer; translates `setConsumerActive` signals into `AudioPipeline.consumerAttached/Detached` (audio-engine-006) |
| `DriverIPCConnection` (protocol) | done | Seam for Tier-1 testing; `XPCDriverIPCConnection` is the production implementation; `FakeDriverIPCConnection` is the test double (audio-engine-006) |
| Virtual-mic publication | not started | infrastructure BC |
