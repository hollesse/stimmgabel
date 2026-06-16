---
id: 0013
title: v1 signing path is Apple Development cert (Keychain locally, GitHub Secret in CI), not true ad-hoc
scope: global
status: accepted
date: 2026-06-16
supersedes: []
superseded_by: []
related_tasks: [infrastructure-010]
related_research: [homebrew-cask-audio-driver-macos26-2026-06-15, homebrew-6-tap-trust-2026-06-16]
---

# ADR 0013: v1 signing path is Apple Development cert (Keychain locally, GitHub Secret in CI), not true ad-hoc

## Context

ADR 0008 framed v1 code signing as **ad-hoc** (`CODE_SIGN_IDENTITY=-`) and
deferred Developer ID + notarisation to v2. That was the plan at modelling
time but doesn't match how Stimmgabel has actually been built:

- `script/build` already runs with `CODE_SIGN_IDENTITY="Apple Development"`,
  `CODE_SIGN_STYLE=Automatic`, `DEVELOPMENT_TEAM=3C96LH326Y`. The walking
  skeleton (infrastructure-006) and every subsequent build use the author's
  Apple Development certificate from their login Keychain. The driver and
  app are both signed against a stable Team-ID-based Designated Requirement.
- That choice was implicit, not recorded. When infrastructure-010
  ("GitHub Release with .pkg installer") needed to decide how the CI runner
  would sign the artefacts, the question surfaced as a genuine choice
  between three paths:

| Option | TCC behaviour across versions | Cost | Gatekeeper UX |
| --- | --- | --- | --- |
| True ad-hoc (`-s -`) | TCC keys on cdhash → permission re-prompt on every update | free | right-click Open every update |
| **Apple Development cert (locally + CI via Secret)** | TCC keys on stable Team-ID DR → permissions persist across updates | free (cert is free with any Apple ID) | right-click Open on first install, "Open Anyway" once for the app on first launch |
| Developer ID + notarisation | TCC stable, Gatekeeper-clean | **$99/year Apple Developer Program** | normal install, no warnings |

The middle path matches what's already in `script/build` locally; the
question for infrastructure-010 was how to extend it to CI. Two CI options:

- **Inject the cert into a fresh keychain via a GitHub Secret** — works,
  needs one-time author setup, needs ~yearly rotation when the cert
  expires.
- **Sign true ad-hoc in CI only** — would diverge the CI artefacts from
  locally-built artefacts and re-introduce the TCC re-prompt problem.

## Decision

- **v1 signs both `Stimmgabel.app` and `Stimmgabel.driver` with an Apple
  Development certificate** (team `3C96LH326Y`, `CODE_SIGN_STYLE=Automatic`).
- Locally, the cert lives in the author's login Keychain as it does today.
  No script change.
- In CI, `.github/workflows/release.yml` imports a `.p12` export of the
  same cert into a fresh temporary keychain via three repository secrets
  (`APPLE_DEV_CERT_P12_BASE64`, `APPLE_DEV_CERT_PASSWORD`,
  `KEYCHAIN_PASSWORD`). After build/package, the workflow deletes the
  temporary keychain.
- The `.pkg` produced by `script/release` is **intentionally unsigned**.
  `productsign` requires a "Developer ID Installer" certificate which we
  don't have. End users right-click → Open the .pkg the first time, then
  Installer.app handles the install. Documented in the top-level README.
- Author-facing operational guides:
  - `docs/SECRETS.md` — one-time CI setup + cert rotation procedure.
  - `docs/RELEASING.md` — tag-push → smoke-test → publish-draft workflow.

## Consequences

### Positive

- TCC permissions (Microphone, System Audio Recording) persist across
  every Stimmgabel update because the Designated Requirement is stable.
  Teammates install Stimmgabel v0.X.0, grant permissions once, then
  every subsequent .pkg works without re-granting.
- No Apple Developer Program membership required — Apple Development
  certs are free with any Apple ID.
- Local builds and CI builds are signed identically. The CI is not a
  special-case codesign path.
- One-time admin password prompt at install (`Installer.app` postinstall
  restarts `coreaudiod` as root). This is the same single-prompt UX
  goal `vision.md` set against the BlackHole + LadioCast baseline.

### Negative

- The Apple Development cert expires after ~365 days. When it does, the
  `release.yml` workflow breaks until the secret is rotated.
  `docs/SECRETS.md` documents the rotation flow and recommends a
  calendar reminder at month 11.
- The .pkg itself is unsigned. First-time install requires a right-click
  → Open gesture (one-line README instruction). Same friction as today's
  ad-hoc-signed `.app` local install — no worse for teammates.
- First launch of `Stimmgabel.app` still trips Gatekeeper ("Apple
  Development" is not "Developer ID"), so a one-time "Open Anyway" in
  System Settings → Privacy & Security is required. Subsequent launches
  AND subsequent versions launch normally because of the stable DR.
- A `.p12` of the author's signing cert lives in the GitHub repo's
  secret store. This is the standard pattern for Apple-cert-in-CI;
  GitHub Secrets are encrypted at rest and only decrypted into workflow
  env vars at runtime. Still, treat the .p12 password as a real secret.

### Neutral

- The v2 upgrade path to **Developer ID Application + Developer ID
  Installer + notarytool** is unchanged from ADR 0008. When the author
  pays for an Apple Developer Program membership, a follow-up task
  swaps the cert in the secrets, adds `productsign` to `script/release`,
  and adds a `notarytool submit` + `stapler staple` step. ADR 0008's v2
  row stands.

## Relationship to ADR 0008

This ADR **clarifies and supersedes the v1 row of ADR 0008** only. ADR
0008 framed v1 as "ad-hoc signed"; reality is "Apple Development cert
signed". ADR 0008's overall structure (SPM + thin Xcode app + xcodebuild,
v2 = Developer ID + notarise) stays valid. The `superseded_by` field on
ADR 0008 is **not** set, because only one row of it is being clarified
and the rest of the decision still stands.

## Alternatives considered

- **True ad-hoc in CI only.** Rejected. Would force teammates to
  re-grant TCC permissions on every Stimmgabel update because TCC keys
  off cdhash for ad-hoc identities. Defeats the "install and forget"
  promise that distinguishes Stimmgabel from the BlackHole baseline.
- **Developer ID + notarisation now.** Rejected for v1. Requires a paid
  Apple Developer Program membership the author is not ready to commit
  to for a hobby tool. Path is reserved (ADR 0008 v2 row).
- **Homebrew Cask instead of GitHub Releases.** Rejected. Research
  (`homebrew-cask-audio-driver-macos26-2026-06-15` and
  `homebrew-6-tap-trust-2026-06-16`) found that Homebrew 5.0 / 6.0 both
  require Developer ID + notarisation for casks. The Homebrew path is
  reserved for the same v2 upgrade as full Gatekeeper-clean signing.

## References

- ADR 0005 — Audio Server Plugin install (system-domain HAL path)
- ADR 0008 — Build & release tooling (this ADR clarifies its v1 row)
- `infrastructure-010` — task that implemented this CI pipeline
- `docs/SECRETS.md` — author-facing setup + rotation guide
- `docs/RELEASING.md` — author-facing release flow
- `homebrew-cask-audio-driver-macos26-2026-06-15` — why not Homebrew v1
- `homebrew-6-tap-trust-2026-06-16` — Homebrew 6 still requires Dev ID
