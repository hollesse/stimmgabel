# menubar-ui

## Purpose
Present Stimmgabel's only user-visible surface: a menu-bar icon plus a dropdown with two mute toggles and a "consumer attached?" status indicator. Nothing else — no preferences window, no profiles, no hotkeys, no level meters.

## Classification
**supporting**

The value of Stimmgabel lives in `audio-engine`; this context is here to make that engine controllable and observable by the human.

## Actors
- **The human user** — the only direct consumer. Glances at the menu bar to confirm status, opens the dropdown to mute a side, mostly forgets the app exists.
- **audio-engine** — sibling in the same process. Receives mute commands; exposes state the UI reflects (consumer attached, current device names).

## Ubiquitous language

- **Menu-bar icon** — the always-present icon in the macOS menu bar. Tells the user at a glance whether Stimmgabel is idle or active.
- **Icon state** — one of:
  - *idle* — no consumer attached; engine is asleep.
  - *active* — at least one consumer is reading; engine is running.
  - *muted (one side)* — variant rendering to make a non-default mute state visible at a glance.
- **Dropdown** — the menu that opens when the user clicks the icon. Contains the mute toggles, the status indicator, and (presumably) a Quit item.
- **Mute toggle** — a checkable menu item per side ("Mic" / "System audio"). Toggling it sends a command to `audio-engine`.
- **Status indicator** — a line in the dropdown showing whether a consumer is currently attached, and (when active) the names of the current mic and system-output devices.
- **Login item** — the macOS facility that auto-launches Stimmgabel at login. The UI's first-run flow asks whether to enable this.
- **App state** — the user-visible state the UI renders. Distinct from internal engine state; this is the projection.

## Aggregates

Tactical modelling pending. Likely a single small aggregate:

- **AppShell** — protects the invariant *"the menu-bar icon and dropdown always reflect current engine state within one render cycle"*.

## Key events
- **UserToggledSideMute(side)** — user clicked a mute toggle.
- **UserOpenedDropdown** — useful for refreshing the device-name display.

## Key commands (issued to audio-engine)
- **SetSideMute(side, on/off)**

## Relationships with other contexts
- **Partnership with audio-engine** — small shared interface. See `context-map.md`.
- **No styleguide gate** — Stimmgabel has no `design-system` BC (see `context-map.md` for rationale). Frontend tasks in this BC do *not* depend on a styleguide task. If a `design-system` BC is later added, update this note.

## Implementation status

### What exists (menubar-ui-005)

- `MutePreferences` — value type backed by `UserDefaults`. Keys: `com.innoq.stimmgabel.muteMicSide`, `com.innoq.stimmgabel.muteSystemAudioSide`. Defaults to `false` for both sides.
- `AppViewModel` — `@MainActor ObservableObject`. Holds `AudioPipeline` and `DriverOutputAdapter`. On init: reads persisted mute, applies to pipeline. On toggle: persists + calls `AudioPipeline.setSideMute`. Exposes:
  - `menuBarIconName` (computed, SF Symbols)
  - `consumerActive: Bool` (computed from `pipelineState`)
  - `consumerStatusDisplayString: String` ("Active" / "Idle — no app reading")
  - `currentMicDeviceName: String` (proxied from `AudioPipeline`)
  - `currentSystemAudioDeviceName: String` (proxied from `AudioPipeline`)
  - `sysAudioGain: @Published Float` (default 1.0) proxied to `pipeline.sysAudioGain` via `didSet`
  - `micGain: @Published Float` (default 3.0) proxied to `pipeline.micGain` via `didSet`
- `StimmgabelApp` — `MenuBarExtra` wired to `AppViewModel`. Icon: `waveform.slash` (idle), `waveform` (active), `waveform.badge.minus` (active + at least one side muted).
- `MenuBarView` — status section (consumer status + device names) above the mute toggles, then mute toggles ("Mic", "System audio"), separator, Quit.
- `AudioPipeline` exposes `consumerActive`, `currentMicDeviceName`, `currentSystemAudioDeviceName` (plain readable properties updated on consumer attach/detach). `deviceNamesDidChange` callback notifies `AppViewModel` when device names update.
- `UpstreamCaptureAdapter` protocol now includes `deviceName: String`. `MicAdapter` and `SystemAudioAdapter` populate it from `kAudioDevicePropertyDeviceName` via CoreAudio.
- `AudioPipeline.sysAudioGain: Float` (default 1.0, range 0.0–2.0) multiplies the system audio channel in `forwardMixed()`. Not persisted — resets to 1.0 on every app start.
- `AudioPipeline.micGain: Float` (default 3.0, range 0.0–6.0) multiplies the mic channel in `forwardMixed()`. Not persisted — resets to 3.0 on every app start.
- `MenuBarView` shows a labeled "System audio volume" slider (0–200%) and a "Mic volume" slider (0–200%, normalized to default 3.0 = 100%) above Quit.

### Icon states (implemented)

- *idle*: `waveform.slash` — no consumer attached; engine is asleep.
- *active*: `waveform` — consumer reading, no mutes.
- *muted (one side)*: `waveform.badge.minus` — at least one side muted; visible at a glance.

### Status indicator (implemented — menubar-ui-003)

Dropdown layout (from top to bottom):
1. `● Active` or `○ Idle — no app reading` — consumer attachment status
2. `Mic: [device name]` — current default input device name (grayed)
3. `System audio: [device name]` — current default output device name (grayed)
4. Divider
5. Mic / System audio mute toggles
6. Divider
7. System audio volume slider (0–200%, default 100%) — implemented in menubar-ui-004
8. Mic volume slider (0–200%, normalized to default 3.0 = 100%) — implemented in menubar-ui-005
9. Divider
10. Quit

## Open questions
- Mute-state persistence across app restart / reboot — **resolved**: `UserDefaults.standard` behind `MutePreferences` (ADR 0007). **Implemented** in menubar-ui-002.
- First-launch onboarding — what minimum does the user see / approve? At least: microphone permission, system-audio capture permission (whatever the chosen mechanism requires), optional "Add to login items?". Out of scope for vision, in scope for first decision/feature tasks.
- Login-item registration — not yet implemented.
