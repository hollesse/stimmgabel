---
topic: Audio Server Plugin (.driver bundle) loading requirements on macOS 26 (Tahoe / Darwin 25)
date: 2026-06-05
requested_by: work
related_tasks: [infrastructure-003-virtual-mic-publishing-mechanism]
---

# Research: Audio Server Plugin Loading Requirements — macOS 26 Tahoe

## Question

What are the exact requirements for a `.driver` bundle (Audio Server Plugin) to be loaded by
`coreaudiod` via `HALS_RemotePlugInRegistrar` on macOS 26 (Tahoe / Darwin 25)? Specifically:
why does `Attempting to load: Stimmgabel.driver` appear in logs but `Creating remote driver service`
never follows, while every other third-party driver (BlackHole, Zoom, NDI, MSTeams) succeeds?

---

## Summary

- **Hardened runtime is the most likely root cause.** Every known working driver (BlackHole confirmed
  via `flags=0x10000(runtime)`) is signed with `--options runtime`. Stimmgabel's binary shows
  `flags=0x0(none)` — no hardened runtime. `HALS_RemotePlugInRegistrar` almost certainly enforces
  this before spawning the remote driver process. This is the first thing to fix.

- **The Xcode project has `ENABLE_HARDENED_RUNTIME` absent entirely for the driver target.** The app
  target uses `CODE_SIGN_IDENTITY = "-"` (ad-hoc, no team), while the driver target uses
  `CODE_SIGN_IDENTITY = "Apple Development"` but without `ENABLE_HARDENED_RUNTIME = YES`.

- **The Info.plist appears structurally correct** for a basic pure-software virtual device: correct
  HAL plugin type UUID (`443ABAB8-E7B3-491A-B985-BEB9187030DB`), factory UUID,
  `CFBundleExecutable` matches binary name, `CFBundlePackageType = BNDL`. No immediately missing
  keys found by comparison with BlackHole.

- **`AudioServerPlugIn_MachServices` is required only if the plugin communicates with another
  process** via Mach IPC. It is not required for a standalone virtual device. An empty array or
  omission is acceptable for a self-contained driver. This is not the blocker.

- **No evidence of macOS 26-specific new loading requirements** beyond what already applied since
  macOS 12/13. The Tahoe audio changes documented publicly are about audio capture bugs (Rogue
  Amoeba) and hardware compatibility (M-Audio, UAD), not plugin loading mechanism changes.

- **Apple Development certificate is sufficient** for development/testing on a registered machine.
  Developer ID is required for distribution to end users / notarization. Certificate type alone
  does not explain the load failure.

---

## Findings

### 1. What `HALS_RemotePlugInRegistrar` checks before creating a remote driver service

No public Apple documentation or official source describes the exact checks inside
`HALS_RemotePlugInRegistrar`. However, the behavior is inferrable from:

- Coreaudiod since macOS 12 (Monterey) on Apple Silicon delegates AudioServerPlugin execution to
  an XPC helper: `/System/Library/Frameworks/CoreAudio.framework/Versions/A/XPCServices/
  com.apple.audio.Core-Audio-Driver-Service.helper.xpc` [7]. This XPC helper spawns the plugin
  as an independent sandboxed process — the "remote driver service."

- The XPC service spawn is what generates "Creating remote driver service" in logs. Its absence
  means the registrar rejected the plugin before requesting the XPC helper to spawn it.

- The most likely rejection criteria at this stage (based on cross-source analysis):
  1. **Hardened runtime not enabled** on the binary — the XPC spawn infrastructure requires it
     (inferred from universal presence on all working drivers; see section 3).
  2. **Incorrect or missing CFPlugInTypes UUID** — already fixed in Stimmgabel.
  3. **Missing CFBundleExecutable or mismatch** with actual binary — already fixed.
  4. **Binary architecture mismatch** — unlikely given it's building against macOS 26.2 SDK.
  5. **Corrupted/invalid code signature** — possible if `--deep` causes issues (see section 3).

*Single-source caveat*: The hardened-runtime-as-gatekeeper theory is inferred from circumstantial
evidence (all working drivers have it, broken driver does not) rather than an explicit Apple
statement. It is the strongest candidate.

### 2. Required Info.plist keys

Comparison of Stimmgabel's built Info.plist against BlackHole's confirmed working plist and Apple's
`AudioServerPlugIn.h` header documentation [3]:

**Confirmed required:**

| Key | Stimmgabel current | BlackHole | Notes |
|-----|-------------------|-----------|-------|
| `CFBundlePackageType` | `BNDL` | `BNDL` | Must be `BNDL`, not `APPL` |
| `CFBundleExecutable` | `Stimmgabel` | matches binary | Must match binary name exactly |
| `CFBundleIdentifier` | `com.innoq.stimmgabel.driver` | `audio.existential.BlackHole` | Unique reverse-DNS |
| `CFPlugInTypes` | `443ABAB8-...` | same UUID | HAL plugin type; correct |
| `CFPlugInFactories` | `ECBECA3C-...` → `AudioServerPlugInDriverCreate` | similar | Factory UUID → function name |

**Optional / situational:**

| Key | Required? | Notes |
|-----|-----------|-------|
| `AudioServerPlugIn_MachServices` | Only if using Mach IPC to external process | Apple TQ QA1811 [4]; empty array or absent is fine for pure virtual device |
| `AudioServerPlugIn_LoadingConditions` | Only if driver should only load when specific IOService exists | Not needed for software-only virtual device |
| `AudioServerPlugIn_Network` | Only if plugin needs network access | Not needed |
| `AudioServerPlugIn_IOKitUserClients` | Only if plugin uses custom IOKit user clients | Not needed |
| `LSMinimumSystemVersion` | Recommended, not required | Stimmgabel has `14.0`; fine |

**Not found to be required for the classic AudioServerPlugin model:**
- `Load As Application` (value `1`) — this is only needed when packaging an AudioServerPlugin that
  communicates with a DriverKit dext and needs to carry driverkit entitlements [3]
- `AudioServerPlugIn_HostInfo` — undocumented, not seen in working drivers

Stimmgabel's Info.plist appears structurally complete. The plist is not the primary suspect.

### 3. Code signing requirements — the primary suspect

**Hardened runtime (`--options runtime` / `ENABLE_HARDENED_RUNTIME = YES`):**

- BlackHole's installer script signs with: `codesign --force --deep --options runtime --sign $devTeamID` [5]. The installed binary shows `flags=0x10000(runtime)`.
- Stimmgabel's Xcode project (`project.pbxproj`) has `ENABLE_HARDENED_RUNTIME` entirely absent from
  the `StimmgabelDriver` build configurations (lines 439–471). The binary shows `flags=0x0(none)`.
- Apple's melatonin.dev guide for audio plugin CI signing specifies `--options=runtime` as
  "necessary if you want to notarize (which you do)" [10].
- Apple Developer Forums thread 122467 (Quinn "The Eskimo!", Apple DTS): macOS 10.15+ applies
  security checks to bundled executables system-wide, and hardened runtime is part of the
  requirements for trusted execution [6].
- The hypothesis: `HALS_RemotePlugInRegistrar` enforces the hardened runtime bit as a prerequisite
  for spawning the remote driver process via the XPC helper. Without it, the registrar silently
  aborts after "Attempting to load."

**`--deep` flag concern:**
The project currently sets `OTHER_CODE_SIGN_FLAGS = "--deep"`. Apple's documentation and multiple
developer reports warn that `--deep` on nested bundles can create an invalid signature state by
re-signing internal content inconsistently. For a simple `.driver` with no sub-bundles, `--deep`
is harmless but adds no value. It should be removed and replaced with explicit signing of the bundle
only. BlackHole's installer does use `--deep` successfully, so this is lower-priority.

**Certificate type (Apple Development vs Developer ID):**
- Apple Development certificates are sufficient for loading on a registered development machine.
- Developer ID Application certificates are required for distribution to end users and for
  notarization.
- The current `TeamIdentifier=3C96LH326Y` is present and valid — the certificate itself is not
  the issue. Certificate type alone does not prevent `HALS_RemotePlugInRegistrar` from loading.

**Notarization:**
Not required for loading on the developer's own machine. Required for distribution. Not the
current blocker.

**Entitlements:**
No special entitlements are required for a pure software virtual audio device. The auto-generated
`Entitlements.plist` in the derived build contains only `com.apple.security.get-task-allow`
(debug entitlement), which is correct for development builds. No production entitlements needed
unless the driver communicates with a DriverKit dext or external XPC service.

### 4. Bundle structure

The classic AudioServerPlugin bundle structure is:

```
Stimmgabel.driver/
  Contents/
    MacOS/
      Stimmgabel          (the executable, Mach-O dylib or executable)
    Info.plist
    _CodeSignature/        (generated by codesign)
      CodeResources
```

Stimmgabel's bundle (from the dist build) follows this structure. No `Resources/` folder is
required. No XPC service sub-bundle is needed for a standalone virtual device. No helper tools
are required.

**Mach-O type:** The bundle should be built as either a dynamic library (`MH_BUNDLE`) or,
in newer configurations with DriverKit integration, as an executable. For the classic CFPlugIn
model, `com.apple.product-type.bundle` (Xcode) producing a Mach-O bundle type is correct.
The "Load As Application" / executable Mach-O type requirement only applies to DriverKit-backed
drivers [3]. Stimmgabel's current `productType = "com.apple.product-type.bundle"` is correct.

### 5. macOS 26 specific changes

No evidence of architectural changes to the `AudioServerPlugin` loading mechanism in macOS 26
Tahoe that would add new requirements beyond what was introduced in macOS 12 (Monterey):

- The Rogue Amoeba macOS 26.1 audio fix list covers audio capture regressions, not plugin loading [8].
- Sweetwater and Production Expert compatibility charts discuss DAW/hardware compatibility, not
  driver plugin loading mechanism changes.
- Audio glitch threads (Apple Discussions, Gearspace) relate to output quality bugs, not plugin
  registration.
- The architecture of `com.apple.audio.Core-Audio-Driver-Service.helper.xpc` as the remote driver
  host (introduced in macOS 12) appears unchanged in macOS 26.

**What DID change in macOS 12 (still applies):**
Before macOS 12 on Intel, plugins loaded in-process within coreaudiod. Since macOS 12 on Apple
Silicon (and progressively on Intel), plugins run in their own sandboxed process spawned by the
XPC helper. This means:
- Hardened runtime enforcement at spawn time is more strictly applied (XPC spawn policy)
- The plugin cannot be debugged by attaching to coreaudiod; attach to the spawned process instead
- SIP must be disabled to attach a debugger [9]

### 6. Reference implementations — signing configuration

**BlackHole (confirmed working):**
- Build: `ENABLE_HARDENED_RUNTIME = YES` via Xcode project [5]
- Sign: `codesign --force --deep --options runtime --sign Q5C99V536K`
- Result: `flags=0x10000(runtime)`, `TeamIdentifier=Q5C99V536K`
- Info.plist: `CFBundlePackageType=BNDL`, correct type/factory UUIDs, no `AudioServerPlugIn_MachServices`

**BackgroundMusic:**
- Build/sign: Details not confirmed from source review; known to work; follows same model
- Info.plist: Has `AudioServerPlugIn_MachServices` as the driver communicates with its app helper

**Apple SimpleAudioDriver sample:**
- This sample is DriverKit-based (dext + AudioServerPlugin wrapper), not a pure AudioServerPlugin.
  Its signing requirements (DriverKit entitlements, provisioning profiles) do NOT apply to
  Stimmgabel's pure AudioServerPlugin model. Treat this sample as irrelevant for the current issue.

**AudioCap (insidegui):**
- Uses `CATapDescription` / `AVAudioEngine` process tap API (macOS 14.4+), not AudioServerPlugin.
  Not relevant.

---

## Actionable Fixes (Priority Order)

1. **Add `ENABLE_HARDENED_RUNTIME = YES` to the `StimmgabelDriver` build target** (both Debug and
   Release configurations in `project.pbxproj`). This is the highest-confidence fix.

2. **Verify the binary shows runtime flag after rebuild:**
   ```
   codesign -dv --verbose=4 /Library/Audio/Plug-Ins/HAL/Stimmgabel.driver
   ```
   Expected: `flags=0x10000(runtime)` instead of `flags=0x0(none)`.

3. **If still not loading, check full coreaudiod logs** for any message after "Attempting to load":
   ```
   log stream --predicate 'process == "coreaudiod"' --level debug
   ```
   Look for: sandbox denial, entitlement rejection, code signing error (`errSecCSUnsigned`,
   `CSSMERR_TP_NOT_TRUSTED`), or architecture mismatch.

4. **Remove `--deep` from `OTHER_CODE_SIGN_FLAGS`** once hardened runtime is enabled. Sign the
   bundle itself; let Xcode handle the contents.

5. **No Info.plist changes needed** unless diagnostics reveal otherwise.

---

## Sources

1. [Building an Audio Server Plug-in and Driver Extension — Apple Developer Documentation](https://developer.apple.com/documentation/CoreAudio/building-an-audio-server-plug-in-and-driver-extension) — Official Apple docs on ASP + DriverKit model. Undated.

2. [Creating an Audio Server Driver Plug-in — Apple Developer Documentation](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in) — Official Apple docs on classic AudioServerPlugin. Undated.

3. [AudioServerPlugIn.h (macOS 11.3 SDK) — phracker/MacOSX-SDKs on GitHub](https://github.com/phracker/MacOSX-SDKs/blob/master/MacOSX11.3.sdk/System/Library/Frameworks/CoreAudio.framework/Versions/A/Headers/AudioServerPlugIn.h) — Header documenting Info.plist keys, sandbox constraints, "Load As Application" requirement.

4. [Technical Q&A QA1811: AudioServerPlugIn_MachServices plist Key — Apple](https://developer.apple.com/library/archive/qa/qa1811/_index.html) — Official explanation of Mach service declaration requirement.

5. [BlackHole create_installer.sh — ExistentialAudio/BlackHole on GitHub](https://github.com/ExistentialAudio/BlackHole/blob/master/Installer/create_installer.sh) — Confirms `--options runtime` signing and `ENABLE_HARDENED_RUNTIME = YES`.

6. [Loading un-notarized plugins on macOS 10.15 — Apple Developer Forums thread/122467](https://developer.apple.com/forums/thread/122467) — Quinn "The Eskimo!" confirms system-wide hardened runtime/notarization requirements from Catalina onward.

7. [Debugging AudioServerPlugin on Apple Silicon Monterey — CoreAudio API mailing list](https://www.mail-archive.com/coreaudio-api@lists.apple.com/msg01798.html) — Confirms plugins run in `com.apple.audio.Core-Audio-Driver-Service` process on Apple Silicon. ~2022.

8. [macOS 26 (Tahoe) Includes Important Audio-Related Bug Fixes — Rogue Amoeba blog](https://weblog.rogueamoeba.com/2025/11/04/macos-26-tahoe-includes-important-audio-related-bug-fixes/) — Tahoe audio fixes; confirms no loading mechanism changes. November 2025.

9. [Help in debugging an Audio Server Plugin — Apple Developer Forums thread/712359](https://developer.apple.com/forums/thread/712359) — Documents SIP must be off to debug; plugins run in own process.

10. [How to code sign and notarize macOS audio plugins in CI — melatonin.dev](https://melatonin.dev/blog/how-to-code-sign-and-notarize-macos-audio-plugins-in-ci/) — `--options=runtime` required; Developer ID for distribution. 2022+.

11. [Entitlements for a virtual audio driver — Apple Developer Forums thread/736357](https://developer.apple.com/forums/thread/736357) — Confirms AudioServerPlugin is the correct model for virtual devices; no special entitlements for pure software device. 2024.

12. [Sandbox needs to be extended — BackgroundMusic GitHub issue #72](https://github.com/kyleneideck/BackgroundMusic/issues/72) — Mach service sandbox error in practice; confirms plugin loads correctly once signed.

13. [core audio user-space driver sandboxing — Apple Developer Forums thread/22659](https://developer.apple.com/forums/thread/22659) — Sandbox restrictions for AudioServerPlugin; `AudioServerPlugIn_MachServices` usage.

---

## Open Questions

1. **Is hardened runtime enforcement by `HALS_RemotePlugInRegistrar` documented anywhere officially?**
   The theory is well-supported by circumstantial evidence but no Apple statement explicitly says
   "the registrar rejects non-hardened-runtime binaries." Requires empirical test.

2. **Does the installed driver at `/Library/Audio/Plug-Ins/HAL/Stimmgabel.driver` match what the
   build produces?** The installer/copy step needs verification — an incorrectly installed driver
   (wrong permissions, wrong path, stale previous version) could also cause the load to silently fail.
   Verify with: `ls -la /Library/Audio/Plug-Ins/HAL/` and `codesign -dv --verbose=4` on the installed bundle.

3. **Does the driver correctly export the `AudioServerPlugInDriverCreate` symbol?**
   The Info.plist references this as the factory function. If the C symbol is not exported (hidden
   visibility), CFPlugIn cannot instantiate the driver. Verify with:
   `nm -g /Library/Audio/Plug-Ins/HAL/Stimmgabel.driver/Contents/MacOS/Stimmgabel | grep AudioServerPlugInDriverCreate`
   It must be a visible `T` (text) symbol.

4. **Are there macOS 26-specific provisioning profile requirements for Apple Development signed
   drivers?** Apple Development certificates now require a provisioning profile on some platforms.
   The Xcode project has `PROVISIONING_PROFILE_SPECIFIER = ""` (empty). If macOS 26 tightened this
   requirement for driver bundles, a provisioning profile might be needed even for dev builds.
   Cannot be confirmed from available sources.

5. **What does the full coreaudiod log show between "Attempting to load" and the next event?**
   Debug-level logs may reveal the exact rejection reason (e.g., `errSecCSUnsigned`,
   `errSecCSWeakResourceRules`, sandbox denial). This is the fastest path to definitive diagnosis.
