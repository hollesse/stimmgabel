# Vision: Stimmgabel

> A macOS menu-bar utility that merges the system's default microphone with all system audio into a single virtual microphone — so other apps just see "Stimmgabel" as a normal input device. Replaces the fragile BlackHole + LadioCast setup with one tool that follows the system defaults automatically.

The name **Stimmgabel** ("tuning fork" in German) is a pun on *Stimme* (voice) + *Gabel* (fork) — forking the voice and system audio streams together into one mic.

## Purpose

When someone wants a downstream app (transcription, recording, screen capture, AI-driven tooling) to hear both their own microphone *and* whatever else is playing on the Mac (meeting audio, browser audio, anything), the current state of the art is a brittle stack of virtual drivers and routing apps. Stimmgabel collapses that to a single app: install it, point your consumer app at the "Stimmgabel" input, forget it exists.

## Users

- **Primary (v1):** Joshua at INNOQ, who needs a clean recording mix of his voice + meeting audio for live transcription with [Handy](https://github.com/cjpais/Handy).
- **Secondary (post-v1):** members of his INNOQ team who practise ensemble programming and want every team member to have the same routing tool installed — so transcription-driven AI workflows keep working when the driver / screen-sharer rotates.
- All users are local to their own Mac. Stimmgabel is never multi-user, never networked.

## The problem

Today, capturing "my mic + what's playing on my Mac" into a single audio stream requires:

- **BlackHole** as a virtual audio driver
- **LadioCast** (or similar) as a software mixer
- Manually selecting BlackHole as a macOS output (or aggregate device)
- Picking the custom input/output devices inside Zoom
- Re-configuring all of the above when the active microphone changes mid-session

The setup is brittle. Switching mics breaks transcription. Multiple background apps need to run. There is no single "off switch". The friction discourages everyday use, and onboarding a team-mate to the same workflow is painful enough that nobody bothers.

## What success looks like

- The author abandons BlackHole + LadioCast and uses only Stimmgabel daily.
- Mid-meeting microphone changes (e.g. AirPods → USB mic) are transparent to the consuming app — transcription does not pause, the user does not change a single setting.
- The macOS microphone indicator only lights up while a downstream consumer is actually reading from Stimmgabel. It does *not* glow continuously.
- Setup for a new user (a teammate, eventually) is: install the app, run the driver-install script (one admin password prompt), grant audio permission once, done.

## Non-goals (v1)

- **Not a recording app** — Stimmgabel produces a live audio stream, nothing more. Persisting bytes to disk is the consumer's job.
- **Not a mixer** — no live faders, no level meters, no per-source gain. A binary mute per side is the entire mixing surface.
- **Not for music production** — voice/meeting fidelity is enough; we accept whatever quality the macOS audio frameworks naturally deliver.
- **Not a per-app audio router** — system audio is *all* system audio (Zoom + Spotify + browser + notifications, all at once). Per-app selection is an explicit future iteration, not v1.
- **Not multi-virtual-mic** — exactly one virtual input device.
- **Not multi-user, networked, or cloud-synced.** No server component ever.
- **Not fully Developer-ID signed and notarised in v1** — the build ad-hoc-signs both the app and the Audio Server Plugin (research showed truly unsigned plug-ins do not reliably load on current macOS, see ADRs 0005 / 0008). Full Developer ID + notarisation is a v2 concern once the app ships beyond the author.
- **Not a settings-rich app** — the menu-bar dropdown is the entire UI. No preferences window, no profiles, no hotkeys.

## Core promise

> **Stimmgabel follows your system defaults — you never have to change a setting anywhere else.**

This single sentence is the contract. Everything else in v1 exists to make this true.

## Ubiquitous language (seed)

- **Virtual mic** — the audio input device Stimmgabel publishes to macOS, named "Stimmgabel". Other apps see it like any normal microphone.
- **Mix** — the live audio stream Stimmgabel produces, combining the mic side and the system-audio side.
- **Mic side** — the half of the mix sourced from the macOS default *input* device. Re-binds when the default changes.
- **System-audio side** — the half of the mix sourced from *all* audio playing on the Mac. Not per-app.
- **Consumer** — any other app reading from the virtual mic (Zoom, Handy, OBS, screen recorders, transcribers).
- **Lazy activation** — Stimmgabel only opens its upstream captures (mic + system audio) while a consumer is actively reading. Idle = silent, no mic indicator, no CPU.
- **Mute (per side)** — a binary toggle that drops one side from the mix. The other side keeps flowing.
- **Default tracking** — Stimmgabel re-binds to whatever macOS currently considers the default input or output device, without user action.

Expect this list to evolve.

## Open questions

- **Mute persistence** across app restart / reboot — assumed yes (set-and-forget); revisit if surprising in practice.
- **Auto-launch on macOS login** — assumed yes-with-first-run-prompt; revisit.
- **Minimum macOS version** — depends on the system-audio capture mechanism (likely Sonoma+ for ScreenCaptureKit-based capture). Architect decides.
- **Mechanism for publishing the virtual mic device** — Audio Server Plugin? Modern HAL extension? Architect decides.
- **Behaviour when one side is silent** (no system audio playing, or no mic plugged in) — assumed: the available side flows through, the missing side is silent. Confirm with the first running build.
- **Per-app system-audio selection** — explicitly deferred to a future iteration.
