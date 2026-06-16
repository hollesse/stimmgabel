# Stimmgabel

A macOS menu-bar app that publishes a virtual audio input device combining your microphone and system audio.
Designed as a single-admin-prompt replacement for the fragile BlackHole + Multi-Output Device stack.

**Status: walking skeleton** — the virtual device emits silence. Real audio routing is the next feature batch.

## Requirements

- macOS 14.0 (Sonoma) or later
- Admin access (one-time, at install)

## Install

Teammates: install Stimmgabel from the **latest GitHub Release**.

1. Open the [latest release](https://github.com/innoq/stimmgabel/releases/latest)
   and download `Stimmgabel-<version>.pkg`.
2. In Finder, **right-click the downloaded .pkg → Open**. macOS will warn
   about an unidentified developer; click **Open** in the warning dialog.
   _Why right-click?_ The .pkg itself is unsigned (Apple charges $99/year
   for the Developer ID Installer certificate that would make it
   double-clickable). The .app and .driver _inside_ the .pkg are signed.
3. Walk through Installer.app. You will be prompted for your admin
   password **exactly once**. The installer:
   - copies `Stimmgabel.app` to `/Applications/`
   - copies `Stimmgabel.driver` to `/Library/Audio/Plug-Ins/HAL/`
   - restarts `coreaudiod` so the virtual mic appears in audio pickers
4. **First launch of `Stimmgabel.app`** may show a Gatekeeper warning.
   If so: open **System Settings → Privacy & Security**, scroll down to
   the Stimmgabel block, and click **Open Anyway**. This is a one-time
   gesture — subsequent launches, and subsequent installed versions of
   Stimmgabel, launch normally.
5. On first launch the app asks for **Microphone** and **System Audio
   Recording** permissions. These **persist across updates** — you only
   grant them once.

After install you should see `Stimmgabel` listed as an input device in:

- **Audio MIDI Setup** (Applications → Utilities → Audio MIDI Setup)
- Any app's audio input picker (Zoom, QuickTime, Handy, etc.)

### Upgrading

Download the newer `.pkg` from GitHub Releases. Right-click → Open as
before. The installer will replace both bundles in place. **No re-granting
of Microphone / System Audio permissions is needed** — the .app and
.driver are signed with a stable identity, so macOS keeps your TCC grants
across versions.

### Removing Stimmgabel

Two pieces — the app and the driver. Trash the app, run the uninstall
script for the driver:

```sh
sudo rm -rf /Applications/Stimmgabel.app
./script/uninstall-driver.sh
```

`script/uninstall-driver.sh` removes
`/Library/Audio/Plug-Ins/HAL/Stimmgabel.driver` and restarts `coreaudiod`.
You will be prompted for your admin password once. (If you no longer have
the repo checked out, the equivalent is `sudo rm -rf
/Library/Audio/Plug-Ins/HAL/Stimmgabel.driver && sudo killall coreaudiod`.)

## Build from source

For contributors. Teammates who just want to use Stimmgabel should follow
the **Install** section above instead.

### Requirements

- Xcode 16 or later (for building)
- An **Apple Development** code-signing identity in your login Keychain.
  This is free with any Apple ID — Xcode → Settings → Accounts → Manage
  Certificates → + → Apple Development.

### Build

```sh
./script/build
```

Produces `dist/Stimmgabel.app`. Both the app and the embedded
`Stimmgabel.driver` are signed with your Apple Development identity. To
verify the signatures:

```sh
codesign --verify --verbose dist/Stimmgabel.app
codesign --verify --verbose dist/Stimmgabel.app/Contents/Resources/Stimmgabel.driver
```

### Install your locally-built driver

```sh
./script/install-driver.sh
```

You will be prompted for your admin password **once**. All running audio
apps will pause for ~1 second while `coreaudiod` restarts.

### Run

```sh
open dist/Stimmgabel.app
```

A microphone icon appears in the menu bar.

### Package a .pkg locally

```sh
./script/release --version 0.0.1-dev
```

Produces `dist/Stimmgabel-0.0.1-dev.pkg`. Same artefact the CI builds for
real releases. Useful for testing the install flow end-to-end before
cutting a tag.

### Cutting a real release

See [`docs/RELEASING.md`](docs/RELEASING.md) for the author-facing release
flow (tag-push → CI builds .pkg → smoke-test → publish draft on GitHub).
First-time setup of the CI signing secrets is documented in
[`docs/SECRETS.md`](docs/SECRETS.md).

## Run the unit tests

```sh
# Via Swift Package Manager (fastest):
swift test

# Via xcodebuild (matches CI):
xcodebuild test -project App/Stimmgabel.xcodeproj -scheme AudioEngineTests -destination "platform=macOS"
```

## Project layout

```
Package.swift                   SPM manifest: AudioEngine + MenubarUI libraries
Sources/AudioEngine/            AudioPipeline, UpstreamCaptureAdapter (no UI imports)
Sources/MenubarUI/              StimmgabelApp (SwiftUI MenuBarExtra)
Tests/AudioEngineTests/         Tier-1 unit tests (fake adapters, no CoreAudio required)
App/Stimmgabel.xcodeproj        Xcode project: Stimmgabel.app + StimmgabelDriver + AudioEngineTests
App/StimmgabelDriver/           Audio Server Plugin C source + Info.plist
script/build                    Build script → dist/Stimmgabel.app
script/release                  Build + package → dist/Stimmgabel-<version>.pkg
script/install-driver.sh        Install Stimmgabel.driver → /Library/Audio/Plug-Ins/HAL/
script/uninstall-driver.sh      Remove Stimmgabel.driver
.github/workflows/release.yml   CI: tag-push → build & sign → draft GitHub Release
docs/SECRETS.md                 One-time GitHub Secrets setup (cert in CI)
docs/RELEASING.md               Author's release flow
dist/                           Build output (gitignored)
```

## Notes

- **Signing:** v1 uses an **Apple Development** certificate (free with any
  Apple ID), not Developer ID. Gatekeeper still warns on first launch
  ("Open Anyway" once), but TCC permissions persist across updates. See
  [ADR 0013](.agentheim/knowledge/decisions/0013-v1-signing-apple-development-cert-via-ci-secret.md).
  A future v2 will move to Developer ID + notarisation, which removes the
  Gatekeeper warning entirely; that's gated on paying for an Apple
  Developer Program membership.
- The virtual mic currently emits **silence**. Actual mic and
  system-audio routing comes in the next feature batch.
