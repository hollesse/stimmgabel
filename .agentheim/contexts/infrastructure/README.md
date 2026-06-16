# infrastructure

## Purpose
Owns Stimmgabel's **globally-true tech concerns** — decisions and assets that apply across every BC, not specific to any single domain context. Initial scope:

- App bundle structure and entitlements
- Build / release tooling
- Code-signing roadmap: v1 uses Apple Development cert (free, ADR 0013); v2 = Developer ID + notarisation (ADR 0008 v2 row, gated on Apple Developer Program membership)
- Distribution channel: v1 = GitHub Releases with CI-built `.pkg` (infrastructure-010). Homebrew Cask deferred to v2 — see related research reports.
- CI: GitHub Actions, `macos-latest` runner, tag-push triggered (`.github/workflows/release.yml`)

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
**Yes — acceptable for v1.** Single `sudo` prompt confirmed sufficient for the author's own workflow. For teammates, infrastructure-010 added a `.pkg` installer (CI-built on `v*` tag push, attached to a GitHub Release draft) that wraps the same `Stimmgabel.app` + `Stimmgabel.driver` in an Installer.app flow with a single admin prompt — so teammates do not need to clone the repo. See ADR 0013 for the Apple-Development-cert-via-CI-Secret signing path.

### Driver IPC (infrastructure-009) implementation notes — macOS 26

**macOS 26 sandbox issue:** `xpc_connection_create_mach_service(..., LISTENER)` returns non-NULL but immediately fires `XPC_ERROR_CONNECTION_INVALID` inside the Remote Driver Service sandbox. XPC IPC is not viable.

**SHM transport (ADR 0012):** App creates POSIX SHM `/stimmgabel-audio-v1` via `sg_shm_open` (a thin C wrapper around `shm_open` — required because `shm_open` is variadic and unavailable from Swift). The shared segment holds `SHMAudioBuffer { _Atomic(uint64_t) writePos, readPos; float samples[4096*2]; }` (layout in `Sources/DriverIPC/include/SGSharedAudio.h`). App increments `writePos` with a release barrier after writing; driver reads with `memory_order_acquire`. On teardown, the app calls `sg_shm_unlink`.

**Darwin notify (ADR 0012):** Driver calls `notify_post(SG_NOTIFY_ACTIVE)` on `StartIO` and `notify_post(SG_NOTIFY_INACTIVE)` on `StopIO`. App registers with `notify_register_dispatch` in `SHMDriverIPCConnection.connect()`.

**Swift interop:** `sg_shm_open` / `sg_shm_unlink` are in `Sources/DriverIPC/include/SGSharedMemory.h` (public headers of the `DriverIPC` C target). `AudioEngine` target now depends on `DriverIPC`. The `notify` module is imported in Swift via `import notify` (module is in libSystem, no extra linker flags needed).

**Ring buffer (kept in DriverIPC, tests still pass):** `SGRingBuffer.{h,c}` in `Sources/DriverIPC/` remains — it is tested by `DriverIPCTests`. The driver-internal copy in `StimmgabelDriver.c` was removed in infrastructure-009.

**REFIID on macOS 26:** In macOS 26 SDK, `REFIID = CFUUIDBytes` (struct by value). Compare with `memcmp(&inUUID, bytes, sizeof(CFUUIDBytes))` — do NOT call `CFUUIDGetUUIDBytes()`.

**Known limitation:** `GetZeroTimeStamp` still returns a fixed `startHostTime` (never advances). Timing drift once real audio flows — follow-up task needed.

### Other open questions
- Sandbox compatibility of `AudioHardwareCreateProcessTap` — deferred to the Process Tap feature task (see Q2 above).
- `GetZeroTimeStamp` timing drift — fix in a follow-up if audible.
