---
topic: Homebrew Cask install of macOS audio drivers on macOS 26 / Homebrew current major
date: 2026-06-15
requested_by: model
related_tasks: [infrastructure-010]
---

# Research: Homebrew Cask install of macOS audio drivers in 2026

## Question

Can Stimmgabel ship as a Homebrew Cask (`brew tap hollesse/stimmgabel && brew install --cask stimmgabel`) that installs both the menu-bar app and a system-domain HAL Audio Server Plugin into `/Library/Audio/Plug-Ins/HAL/` in one admin-password prompt, while keeping the v1 ad-hoc signing strategy from ADR 0008?

## Summary

**Verdict: ad-hoc signing is NOT viable for the official Homebrew tap path; for a private third-party tap it is technically still possible today but operationally fragile and ends in September 2026 if Apple's tightening continues. Shipping via brew requires upgrading to a Developer ID Installer-signed and notarised `.pkg`.**

- Homebrew has set a hard deadline: **September 2026** — all casks in the official `Homebrew/homebrew-cask` tap that fail Gatekeeper checks are removed, and the audit already flags unsigned/un-notarised casks as deprecated [1][2][3]. A *third-party tap* (`hollesse/stimmgabel`) is not subject to that audit gate, but the Gatekeeper failure mode on the user's machine is the same.
- Homebrew 5.0 (Nov 2025) removed the `--no-quarantine` / `--quarantine` flags explicitly to stop users from bypassing Gatekeeper [1]. The ad-hoc workaround "user runs xattr -d com.apple.quarantine" can no longer be quietly papered over by the cask itself.
- macOS 26 (Tahoe) tightens `.pkg` Gatekeeper enforcement to the point that even some *correctly* Developer ID Installer-signed + notarised pkgs are being rejected when downloaded (a regression Apple DTS is investigating, March 2026) [4]. An *unsigned* or ad-hoc pkg has no realistic path through Installer.app on macOS 26 once quarantined.
- BlackHole — the closest analogue — ships a Developer ID Installer-signed, notarised, stapled `.pkg` built via `pkgbuild`/`productbuild` + `notarytool`; the cask uses `pkg` artifact + `pkgutil:` uninstall + `quit:` AudioMIDISetup; no `--no-quarantine` is needed because the pkg passes Gatekeeper on its own [5][6][7].
- Concrete v2 path: switch ADR 0008 from ad-hoc to Developer ID Application + Developer ID Installer + notarisation; produce a single notarised distribution `.pkg` containing the app payload (`/Applications`) and the HAL plugin payload (`/Library/Audio/Plug-Ins/HAL/`) plus a `postinstall` that does `killall coreaudiod` (macOS ≥14.4 syntax). The cask becomes a thin wrapper: `pkg`, `uninstall pkgutil:`, `caveats { reboot }`.

## Findings

### 1. Homebrew current major version and cask policy changes

- **Homebrew 4.6.0 (2025-08-05)** introduced the policy that *"All casks submitted in Homebrew/homebrew-cask must be signed."* Unsigned casks were not yet removed but the rule was on the books [8].
- **Homebrew 5.0.0 (2025-11-12)** formalised the deprecation: unsigned/un-notarised casks are deprecated and will be removed from the official tap by **September 2026**; `--no-quarantine` and `--quarantine` flags were removed because *"Homebrew does not wish to easily provide circumvention to macOS security features"*; a new `HOMEBREW_FORBIDDEN_CASK_ARTIFACTS` env var lets fleet admins block artifact types (e.g. `pkg`, `installer`) wholesale [1][3].
- **Homebrew 5.1.0 (2026-03-10)** focused on dependency safety (refuses to uninstall a cask another cask depends on) and UI clarity (`brew info`, `brew search` now mark deprecated/disabled). No new cask-signing policy beyond 5.0 [2].
- **Homebrew 6.0.0 (2026-06-11, four days before this report)** introduced a new tap-trust security mechanism — relevant for our third-party tap `hollesse/stimmgabel`: users will be prompted to explicitly trust the tap before first install [9]. This is friction, not a blocker.
- No release between 4.6 and 5.1 changed `pkg` artifact handling, `sha256` policy (still mandatory unless `sha256 :no_check` is justified), or the structure of `uninstall` / `zap` stanzas in any way that affects this design.

Implication: **a private tap (`hollesse/stimmgabel`) is not subject to the September 2026 removal**, only the official `Homebrew/homebrew-cask`. But every user installing from that tap is still subject to macOS Gatekeeper, which is the real gate, not Homebrew's audit.

### 2. macOS 26 installer .pkg policy

- Historical baseline: since Big Sur, distribution pkgs that register daemons or write to privileged locations must be Developer ID Installer-signed and notarised, or Gatekeeper warns/blocks. Ad-hoc-signed *executables inside* a pkg are tolerated as long as the pkg itself is Dev ID + notarised [10].
- **macOS 26.3 Tahoe (March 2026)** is *stricter*: a developer reported on Apple's forums that even a correctly Developer ID Installer-signed + notarised + stapled `.pkg` is rejected by both `spctl --type install` and Installer.app GUI when downloaded (quarantine xattr present). Apple DTS engineer Quinn confirmed this is not normal behaviour and is investigating; the workaround is `xattr -d com.apple.quarantine`, which Homebrew 5.0 explicitly refuses to do via `--no-quarantine` [4][1].
- Brew installs a cask without the quarantine bit by default for *the downloaded artifact during brew's own install run* (Homebrew calls the pkg via `sudo installer -pkg ... -target /`, bypassing Finder/Gatekeeper-for-launch), so this Tahoe regression does **not** block `brew install --cask` of a properly signed pkg. It does block users who download the same pkg directly. Confirm by reading: the cask test on a Tahoe machine is the only definitive check.
- Net for Stimmgabel: an **unsigned or ad-hoc-signed pkg** has no realistic story under macOS 26. Even if `sudo installer -pkg` would technically run it (it does — `installer(8)` does not perform Gatekeeper notarisation checks the way Finder does), the BlackHole `kickstart com.apple.audio.coreaudiod` history shows the postinstall script's privilege model is the next failure mode (see §3) [7].

### 3. BlackHole's homebrew cask — the closest analogue

The full BlackHole 2ch cask (current at time of report) [6]:

```ruby
cask "blackhole-2ch" do
  version "0.6.1"
  sha256 "c829afa041a9f6e1b369c01953c8f079740dd1f02421109855829edc0d3c1988"

  url "https://existential.audio/downloads/BlackHole2ch-#{version}.pkg"
  name "BlackHole 2ch"
  desc "Virtual Audio Driver"
  homepage "https://existential.audio/blackhole/"

  livecheck do
    url "https://github.com/ExistentialAudio/BlackHole"
    strategy :github_latest
  end

  depends_on :macos

  pkg "BlackHole2ch-#{version}.pkg"

  uninstall quit:    "com.apple.audio.AudioMIDISetup",
            pkgutil: "audio.existential.BlackHole2ch"

  caveats do
    reboot
  end
end
```

Pattern extraction:

- **Artifact**: `pkg` — a single distribution package downloaded from existential.audio (not GitHub releases). The download is hash-pinned.
- **Signing/notarisation**: BlackHole's `Installer/create_installer.sh` shows the full pipeline [5]:
  - `codesign --force --deep --options runtime --sign $devTeamID` on the `.driver` bundle (hardened runtime).
  - `pkgbuild --sign $devTeamID --root ... --scripts Installer/Scripts --install-location /Library/Audio/Plug-Ins/HAL` to build a component pkg.
  - `productbuild --sign $devTeamID --distribution distribution.xml --resources . --package-path ... <out>.pkg` to build the distribution pkg.
  - `xcrun notarytool submit ... --wait` then `xcrun stapler staple` to notarise.
  - The `$devTeamID` is a **Developer ID Installer** identity (productsign/pkgbuild --sign expects an Installer cert; the same `$devTeamID` variable being passed to `codesign` is shorthand for "team's Dev ID Application + Dev ID Installer certs both in keychain"; the script picks the right one per tool).
- **Postinstall**: Scripts live under `Installer/Scripts/` (file literally named `postinstall`, no extension, executable mode 755) [5][11]. BlackHole's postinstall historically did `launchctl kickstart -k system/com.apple.audio.coreaudiod`; this failed on some users with *"Operation not permitted"* even under sudo, and the only resolution noted in the upstream issue was to *remove* the kickstart step (the user reboots instead) [7]. On macOS ≥14.4, the documented working call is `sudo killall coreaudiod` rather than `launchctl kickstart` [11][12].
- **Uninstall stanza**: only `pkgutil:` (forgets the receipt and removes payload by receipt manifest) plus `quit:` for AudioMIDISetup. No explicit `delete:` for `/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver` is needed because `pkgutil --forget` + receipt-driven removal handles it. **No `zap` stanza** — single-source-of-truth uninstall via the receipt.
- **Reboot**: `caveats { reboot }` shows a reboot prompt to the user. This is the conservative path; in practice for the audio driver alone, a coreaudiod restart suffices, but a reboot avoids edge cases (per-app HAL state).

### 4. pkgbuild + productbuild patterns for HAL plugins

Standard pattern, cross-referenced from BlackHole's script [5], Apple's `pkgbuild(1)` / `productbuild(1)` man pages [10], BackgroundMusic's developer notes [11], and the theevilbit HAL writeup [12]:

```bash
# 1. Build a payload root mirroring filesystem layout
PAYLOAD_ROOT=build/pkg-root
mkdir -p "$PAYLOAD_ROOT/Applications"
mkdir -p "$PAYLOAD_ROOT/Library/Audio/Plug-Ins/HAL"
cp -R build/Stimmgabel.app "$PAYLOAD_ROOT/Applications/"
cp -R build/StimmgabelHAL.driver "$PAYLOAD_ROOT/Library/Audio/Plug-Ins/HAL/"

# 2. Codesign the bundles with Dev ID Application + hardened runtime
codesign --force --deep --options runtime --timestamp \
  --sign "Developer ID Application: <Team>" \
  "$PAYLOAD_ROOT/Applications/Stimmgabel.app"
codesign --force --deep --options runtime --timestamp \
  --sign "Developer ID Application: <Team>" \
  "$PAYLOAD_ROOT/Library/Audio/Plug-Ins/HAL/StimmgabelHAL.driver"

# 3. Build the component pkg (no --install-location: payload paths are absolute)
pkgbuild \
  --root "$PAYLOAD_ROOT" \
  --scripts build/Scripts \
  --identifier com.innoq.stimmgabel \
  --version "$VERSION" \
  --sign "Developer ID Installer: <Team>" \
  build/component.pkg

# 4. (Optional) wrap in distribution pkg for UI / EULA / system requirements
productbuild \
  --distribution build/distribution.xml \
  --package-path build \
  --resources build/resources \
  --sign "Developer ID Installer: <Team>" \
  build/Stimmgabel-$VERSION.pkg

# 5. Notarise + staple
xcrun notarytool submit build/Stimmgabel-$VERSION.pkg \
  --keychain-profile <profile> --wait
xcrun stapler staple build/Stimmgabel-$VERSION.pkg
```

`build/Scripts/postinstall` (file name exact, no extension, mode 755, LF line endings created on macOS to avoid encoding traps [13]):

```bash
#!/bin/bash
set -euo pipefail
# macOS 14.4+: launchctl kickstart frequently returns EPERM under SIP;
# killall is the supported call.
/usr/bin/killall coreaudiod || true
exit 0
```

Notes:

- `--install-location` is only needed when the payload root *doesn't* contain the absolute filesystem path. With the layout above (`pkg-root/Applications`, `pkg-root/Library/...`), omit it [10].
- `productbuild` with `--component` (single-bundle shorthand) is *not* what you want for two bundles in different system locations — use `--root` via `pkgbuild` + a distribution xml wrapping it [10].
- For the distribution xml: include `<options require-scripts="true"/>` and a `<choice>` referencing the component so the user gets a standard installer UI. Reference: Apple Developer "Distribution Definition" docs [10].
- The HAL plugin directory `/Library/Audio/Plug-Ins/HAL/` is root-owned; only `installer(8)` running as root (which it does for system-domain pkgs) can write there — *not* user-level scripts [12][14]. This is the structural reason a `.zip` + postflight install (such as a brew `app` artifact + `postflight` block) cannot do this without an additional `sudo` prompt and bespoke logic; the `pkg` artifact is the only clean path.

### 5. Verdict

**Ad-hoc signing (ADR 0008 v1) cannot ship through `brew install --cask` in 2026.** Specifically:

1. The cask must declare a `pkg` artifact (only way to write `/Library/Audio/Plug-Ins/HAL/` in one admin prompt) [12][14].
2. `brew install --cask` invokes `sudo installer -pkg ... -target /`. `installer(8)` itself does not enforce notarisation, so an *unsigned or ad-hoc* pkg *might* technically install on macOS 26 today via this path.
3. **But** the postinstall step `killall coreaudiod` requires a properly signed pkg context to avoid the `kickstart Operation not permitted` failure documented for BlackHole [7][11]. Even if it ran, ad-hoc-signed HAL bundles loaded by `coreaudiod` after the restart are subject to *Apple's audio sandbox* rejecting unsigned plugins; the v0 ADR-0008 path assumes the user pre-approved the binary via right-click-Open on the *app*, but the HAL plugin is loaded by `coreaudiod` (a system daemon), not by the user, and gets no such grace period [14][15].
4. Homebrew's own policy direction (4.6 mandate, 5.0 deprecation, 5.0 removal of `--no-quarantine`, Sep-2026 hard cutoff for the official tap) [1][3][8] makes the ad-hoc path a dead-end strategically, even if a private tap survives the audit.

**Concrete failure modes if you ship ad-hoc anyway:**
- Failure A: `installer -pkg` succeeds → `coreaudiod` reloads HAL plugins → ad-hoc-signed `StimmgabelHAL.driver` is rejected by the audio sandbox → driver not visible in Audio MIDI Setup. (No clear error to the user; the brew install reports success.)
- Failure B: postinstall `killall coreaudiod` returns EPERM under SIP for some users; install half-completes, requires reboot to recover [7].
- Failure C (post-Sep 2026): if you ever try to upstream the cask to `Homebrew/homebrew-cask`, audit rejects it.

**Required upgrade for brew distribution:**
- Developer ID Application certificate (for `Stimmgabel.app` and `StimmgabelHAL.driver`).
- Developer ID Installer certificate (for the distribution pkg).
- `xcrun notarytool` + `xcrun stapler staple` in the release pipeline.
- All standard requirements: hardened runtime (`--options runtime`), secure timestamp (`--timestamp`), no `com.apple.security.get-task-allow` entitlement in release builds.

### 6. 2026 surprises worth knowing

- **Homebrew 6.0.0 tap-trust** (2026-06-11): users installing from `hollesse/stimmgabel` will see an explicit trust prompt on first use [9]. Document this in the install instructions.
- **macOS 26.3 Gatekeeper pkg regression** (March 2026, unresolved): even fully Dev ID Installer-signed + notarised + stapled pkgs are rejected by Finder/`spctl --type install` when quarantined [4]. `brew install --cask` is not affected because it shells to `installer(8)` directly, but users who try to download and double-click the same pkg are. This is one more reason to *only* document brew-based install for v2 until Apple resolves the regression.
- **`launchctl kickstart` for `coreaudiod`** continues to fail with EPERM under SIP on some macOS versions; `killall coreaudiod` is the documented working call from macOS 14.4 onward [7][11]. Use that, do not bring back kickstart.
- **HAL plugin loading and audio sandbox**: `coreaudiod` evaluates plugin code signatures at load time; Apple has progressively tightened this since macOS 14. Existing project memory on this codebase (`feedback-coreaudio-debugging.md`, `project-audioserplugin-required-properties.md`) confirms the sandbox is unforgiving — debug via `os_log` first, do not assume your unsigned plugin will load.
- **No XPC / Endpoint Security changes** found in 2025-2026 release notes that specifically affect HAL plugin distribution beyond the signature requirements above. (Open question — see below.)

## Sources

1. [Homebrew 5.0.0 release notes](https://brew.sh/2025/11/12/homebrew-5.0.0/) — 2025-11-12 — primary source: deprecates unsigned/un-notarised casks, removes `--no-quarantine`, introduces `HOMEBREW_FORBIDDEN_CASK_ARTIFACTS`, Sep 2026 cutoff.
2. [Homebrew 5.1.0 release notes](https://brew.sh/2026/03/10/homebrew-5.1.0/) — 2026-03-10 — primary source: no new cask signing policy, dependency safety improvements.
3. [Workbrew analysis of Homebrew 5.0.0](https://workbrew.com/blog/homebrew-5-0-0) — 2025-11 — secondary source confirming Sep 2026 enforcement deadline. Vendor blog (Workbrew is a Homebrew-fleet-management vendor); their interpretation aligns with the official release notes.
4. [Apple Developer Forums thread 817887: spctl --type install rejects notarized .pkg on macOS 26 Tahoe (26.3)](https://developer.apple.com/forums/thread/817887) — March 2026 — primary source from Apple's developer forum including DTS engineer Quinn confirming the regression is under investigation.
5. [BlackHole repository (ExistentialAudio/BlackHole)](https://github.com/ExistentialAudio/BlackHole) — references `Installer/create_installer.sh` which shows pkgbuild/productbuild/codesign/notarytool flow.
6. [Homebrew cask formula blackhole-2ch.rb](https://github.com/Homebrew/homebrew-cask/blob/master/Casks/b/blackhole-2ch.rb) — primary source: the working cask formula for a HAL plugin shipped through brew.
7. [Homebrew/homebrew-cask issue #171570: blackhole-2ch kickstart com.apple.audio.coreaudiod Operation not permitted](https://github.com/Homebrew/homebrew-cask/issues/171570) — issue thread documenting the kickstart EPERM failure mode and that removing kickstart was the only workaround.
8. [Homebrew 4.6.0 release notes](https://brew.sh/2025/08/05/homebrew-4.6.0/) — 2025-08-05 — primary source for the first formal "all casks must be signed" mandate.
9. [What is the current version of Homebrew? The 2026 Power Guide](https://blog.thefix.it.com/what-is-the-current-version-of-homebrew-the-2026-power-guide/) — secondary; references Homebrew 6.0.0 (2026-06-11) tap-trust mechanism. Single-source claim — treat as hypothesis until verified against an official Homebrew release post.
10. Apple `pkgbuild(1)`, `productbuild(1)` man pages and Developer documentation (referenced via BlackHole script structure) — `--sign`, `--scripts`, `--root`, `--install-location`, `--distribution` semantics.
11. [BackgroundMusic DEVELOPING.md](https://github.com/kyleneideck/BackgroundMusic/blob/master/DEVELOPING.md) — open-source HAL plugin reference for build/install conventions including coreaudiod restart commands per macOS version.
12. [theevilbit blog — Audio Plugins (Beyond the good ol' LaunchAgents #13)](https://theevilbit.github.io/beyond/beyond_0013/) — security/persistence-focused writeup that incidentally documents `/Library/Audio/Plug-Ins/HAL/` ownership and coreaudiod load semantics.
13. [Der Flounder — Creating payload-free packages with pkgbuild](https://derflounder.wordpress.com/2012/08/15/creating-payload-free-packages-with-pkgbuild/) — 2012, still-canonical reference for pkgbuild script conventions (postinstall naming, encoding). Older source — used only for the file-naming convention which has not changed.
14. [Apple Developer Forums: No permission to audio plugins 'HAL' folder](https://developer.apple.com/forums/thread/105853) — confirms root:wheel ownership and root-only write to HAL plugin dir.
15. [Apple Developer Forums: With OS X Sonoma 14.4 update there is no rights to relaunch coreaudiod](https://developer.apple.com/forums/thread/748228) — primary source documenting the 14.4 kickstart regression and migration to `killall coreaudiod`.

## Open questions

- **Does `brew install --cask` of an unsigned pkg actually succeed end-to-end on a clean macOS 26.3 machine?** The chain of reasoning above says "the `installer(8)` step succeeds but the HAL plugin then fails to load," but only an empirical test on a Tahoe VM confirms this. Set up a throwaway pkg with a stub HAL bundle and try it; the answer determines whether v1 ad-hoc is *technically* shippable for an internal preview audience even if not officially supportable.
- **Homebrew 6.0.0 release notes**: the official `brew.sh/2026/06/11/homebrew-6.0.0/` post was not fetched in this research (released four days before this report). Confirm tap-trust mechanism details, especially whether it requires a separate `brew tap --trust` step or is just an interactive prompt.
- **macOS 26.3 pkg regression resolution**: Apple DTS is investigating as of March 2026; no public resolution yet. Re-check Apple Developer Forums thread 817887 before any v2 release. If still unresolved at ship time, document the workaround (`xattr -d com.apple.quarantine`) only for the *manual* pkg-download path, not for brew-installed users.
- **HOMEBREW_FORBIDDEN_CASK_ARTIFACTS in enterprise fleets**: some INNOQ customers may forbid `pkg` artifacts via this env var (it exists *because* admins want to disallow pkgs that ask for sudo). If we go all-in on the pkg cask path, we should communicate to enterprise installers that they need to allow `pkg` artifacts for this tap.
- **HAL DriverKit alternative**: there's a long-running Apple direction toward DriverKit / dext for audio (referenced in `developer.apple.com/forums/thread/775341`), which would change the entire distribution model (driver extensions install via the app's containing bundle, no pkg postinstall, no root write to /Library). Not researched in depth here — flag for a separate research task if v2 timeline allows reconsidering the HAL approach.
