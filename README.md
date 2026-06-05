# Stimmgabel

A macOS menu-bar app that publishes a virtual audio input device combining your microphone and system audio.
Designed as a single-admin-prompt replacement for the fragile BlackHole + Multi-Output Device stack.

**Status: walking skeleton** — the virtual device emits silence. Real audio routing is the next feature batch.

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 16 or later (for building)
- Admin access (for installing the Audio Server Plugin)

## Build

```sh
./script/build
```

Produces `dist/Stimmgabel.app`. Both the app and the embedded `Stimmgabel.driver` are ad-hoc signed.

To verify the signatures:
```sh
codesign --verify --verbose dist/Stimmgabel.app
codesign --verify --verbose dist/Stimmgabel.app/Contents/Resources/Stimmgabel.driver
```

## Install the virtual mic driver

The virtual input device ("Stimmgabel") is published by an Audio Server Plugin that must be installed
in `/Library/Audio/Plug-Ins/HAL/`. Run:

```sh
./script/install-driver.sh
```

You will be prompted for your admin password **once**. All running audio apps will pause for ~1 second
while `coreaudiod` restarts. After the restart, a "Stimmgabel" input device appears in:

- **Audio MIDI Setup** (Applications → Utilities → Audio MIDI Setup)
- Any app's audio input picker (Zoom, QuickTime, Handy, etc.)

## Run

```sh
open dist/Stimmgabel.app
```

A microphone icon appears in the menu bar. Click it to see "Stimmgabel — running" and a Quit option.

## Uninstall the driver

```sh
./script/uninstall-driver.sh
```

Removes the driver and restarts `coreaudiod`. The "Stimmgabel" device disappears from all pickers.

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
script/install-driver.sh        Install Stimmgabel.driver → /Library/Audio/Plug-Ins/HAL/
script/uninstall-driver.sh      Remove Stimmgabel.driver
dist/                           Build output (gitignored)
```

## Notes

- **v1 is ad-hoc signed**, not Developer-ID signed. The app can be launched directly after building; no Gatekeeper prompt for locally-built binaries. If you copied the app from another machine, run `xattr -dr com.apple.quarantine dist/Stimmgabel.app` first.
- The virtual mic currently emits **silence**. Actual mic and system-audio routing comes in the next feature batch.
- The install script is the only supported install path in v1. A proper `.pkg` installer or in-app privileged helper comes with v2.
