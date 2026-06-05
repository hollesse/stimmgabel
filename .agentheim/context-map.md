# Context map: Stimmgabel

Stimmgabel is a small single-process macOS app, but it has two distinct concerns with different vocabularies — an audio plumbing layer that thinks in samples, devices, and CoreAudio, and a UI layer that thinks in menu items, toggles, and user-visible state. A third context, `infrastructure`, owns globally-true tech concerns (app bundle, entitlements, build, future code-signing).

## Contexts

### audio-engine
- **Purpose:** capture the macOS default mic + all system audio, mix them, and publish a single virtual input device. Track default-device changes and rebind without user action. Activate lazily when a consumer reads.
- **Classification:** **core** — Stimmgabel's whole reason to exist lives here.
- **Core language:** sample, frame, buffer, sample rate, channel, device, AudioDeviceID, mic side, system-audio side, mix, consumer, lazy activation, default tracking.
- **Key actors:** macOS audio frameworks (CoreAudio / HAL / ScreenCaptureKit) upstream; the virtual-mic consumer app downstream; the menu-bar UI as a sibling that issues commands.

### menubar-ui
- **Purpose:** present the menu-bar icon and dropdown, let the user mute either side, and surface whether a consumer is currently attached. Nothing else.
- **Classification:** **supporting** — necessary, but the value lives in `audio-engine`.
- **Core language:** menu item, dropdown, toggle, status indicator, login item, app state, icon state (idle / active / muted).
- **Key actors:** the human user; the `audio-engine` as a sibling (sends commands, observes state).

### infrastructure
- **Purpose:** globally-true tech concerns — app bundle structure, entitlements, build/release tooling, the code-signing roadmap (deferred for v1), eventual distribution channel, CI if any. The walking-skeleton spike that proves the whole stack runs end-to-end lives here.
- **Classification:** **generic** — nothing domain-specific.
- **Core language:** generic ops vocabulary — bundle, entitlement, signature, notarisation, login item, release. Thin section; this BC's job is to hold decisions, not domain terms.

## No design-system context

The user-facing surface is a menu-bar icon plus a small native dropdown using AppKit/SwiftUI standard controls. There is no visual design language to maintain beyond OS chrome, no custom components, no shared tokens. A `design-system` BC would be ceremony without payoff at this scale.

If Stimmgabel ever grows a preferences window, onboarding screens, or any meaningful visual surface, revisit this decision and add a `design-system` BC then. Until then, every frontend-bearing BC's README skips the styleguide-gate rule.

## Relationships

- **menubar-ui ↔ audio-engine — partnership / shared kernel.** Both live in the same app process and share a small interface: a few commands (`mute mic side`, `unmute system-audio side`) and a few observable states (`consumer attached?`, `current mic device name`, `current system output name`). Tight coupling is fine here — they ship together; the split exists for cognitive clarity, not for deployment independence.

- **infrastructure — upstream of both.** Owns the app bundle, entitlements, and build/release flow. Whatever it provides, the other two BCs run inside.

- **audio-engine — conformist to macOS audio frameworks.** Stimmgabel does *not* abstract CoreAudio behind a portable interface. The architecture follows the platform — if Apple changes the audio APIs, Stimmgabel changes with them.

- **audio-engine ↔ external consumer (Zoom, Handy, OBS, …) — open host / published language.** The published language is "a macOS audio input device" — i.e. the standard CoreAudio device contract. Consumers see Stimmgabel as just another mic; Stimmgabel makes no assumption about who is reading.
