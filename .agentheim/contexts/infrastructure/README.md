# infrastructure

## Purpose
Owns Stimmgabel's **globally-true tech concerns** — decisions and assets that apply across every BC, not specific to any single domain context. Initial scope:

- App bundle structure and entitlements
- Build / release tooling
- Code-signing & notarisation roadmap (deferred for v1 — see ADRs once they land)
- Distribution channel (later — GitHub release, Homebrew tap, …)
- Any future CI

BC-local tech concerns (the specific CoreAudio binding in `audio-engine`, the specific SwiftUI views in `menubar-ui`, the persistence mechanism that lives next to `menubar-ui`'s mute-state) stay inside their originating BC and do *not* belong here.

The **walking-skeleton spike** that proves the whole stack runs end-to-end lives in this BC's `todo/`, because it spans every BC and proves the *whole* stack runs.

## Classification
**generic**

Nothing domain-specific. If a future infra-flavoured decision turns out to be load-bearing for only one BC, route it to that BC's `todo/` instead.

## Actors
- **The author / future operators** — whoever builds, signs, and ships the app.
- **macOS itself** — Gatekeeper, the App Translocation service, the login-items registry, the codesign / notarytool tooling. Stimmgabel must coexist with these whether or not it is signed in v1.

## Ubiquitous language

Thin section — generic ops vocabulary. Recorded here so tasks and ADRs in this BC use it consistently.

- **App bundle** — the `.app` directory macOS treats as a single installable unit.
- **Entitlement** — a permission the app declares it needs (mic access, screen / system-audio capture, etc.). Encoded in the bundle.
- **Signature / notarisation** — the cryptographic chain that lets macOS Gatekeeper trust the app. Deferred for v1; relevant for v2+.
- **Login item** — the macOS facility that auto-launches an app at user login.
- **Release** — a built `.app` ready to be installed somewhere other than the build machine. v1: drag-installed locally. Later: distributed.

## Aggregates / Key events / Key commands
Not applicable — this BC holds tech decisions and shipping assets, not a domain.

## Relationships with other contexts
- **Upstream of audio-engine and menubar-ui.** Whatever bundle, entitlements, and build process this BC defines, the others run inside.
- See `context-map.md`.

## Open questions

### Walking skeleton (infrastructure-006) empirical answers

**Q1 — Ad-hoc-signed Audio Server Plugin loading (macOS 26.3):**
**Yes — ad-hoc signing is sufficient**, once the driver implementation is correct. Initial test showed the device not appearing; root cause was a `QueryInterface` bug (`memcmp(&inUUID, …)` compared stack memory instead of UUID bytes — fixed in infrastructure-007). After the fix, `codesign --verify --verbose` passes and the driver loads. Confirmed on macOS 26.3 (Darwin 25.3.0).

**Q2 — App Sandbox compatibility with `AudioHardwareCreateProcessTap`:**
Not exercised in this spike. The walking skeleton app is **unsandboxed** (no `com.apple.security.app-sandbox` entitlement). The sandbox question applies only when the real Process Tap (ADR 0004) is wired in — that is a follow-up empirical task.

**Q3 — Install UX acceptability (single `sudo` prompt):**
**Yes — acceptable for v1.** Single `sudo` prompt confirmed sufficient. No `.pkg` installer needed for the author workflow.

### Driver IPC (infrastructure-008) implementation notes

**Ring buffer:** 4096 frames × interleaved float32 stereo, lock-free SP/SR with `_Atomic(uint32_t)` heads. Canonical source in `Sources/DriverIPC/SGRingBuffer.{h,c}`; inlined into `StimmgabelDriver.c` to keep the driver self-contained.

**XPC service:** Driver registers `com.innoq.stimmgabel.driver` as Mach service listener (Info.plist `AudioServerPlugIn_MachServices`). App connects as client; sends `writeSamples(data:frameCount:)`. Driver sends `setConsumerActive(bool)` back on `StartIO`/`StopIO`. Only one client accepted at a time.

**REFIID on macOS 26:** In macOS 26 SDK, `REFIID = CFUUIDBytes` (struct by value). Compare with `memcmp(&inUUID, bytes, sizeof(CFUUIDBytes))` — do NOT call `CFUUIDGetUUIDBytes()`.

**Known limitation:** `GetZeroTimeStamp` still returns a fixed `startHostTime` (never advances). Timing drift once real audio flows — follow-up task needed.

### Other open questions
- Sandbox compatibility of `AudioHardwareCreateProcessTap` — deferred to the Process Tap feature task (see Q2 above).
- `GetZeroTimeStamp` timing drift — fix in a follow-up if audible.
