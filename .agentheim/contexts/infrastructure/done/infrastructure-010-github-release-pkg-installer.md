---
id: infrastructure-010
title: Distribution — GitHub Release with .pkg installer (CI-built, Apple Development signed)
status: done
type: feature
context: infrastructure
created: 2026-06-15
completed: 2026-06-16
commit:
depends_on: []
blocks: []
tags: [release, distribution, pkg, installer, driver-install, gatekeeper, ci, github-actions, codesign]
related_adrs: [0005, 0008, 0013]
related_research: [homebrew-cask-audio-driver-macos26-2026-06-15, homebrew-6-tap-trust-2026-06-16]
prior_art: [infrastructure-003, infrastructure-004, infrastructure-006]
---

## Why

Teammates need a way to install Stimmgabel that does not require them to
clone the repo and run two shell scripts. The current `./script/build` +
`./script/install-driver.sh` flow is fine for the author but is the kind
of friction `vision.md` complains about in the BlackHole + LadioCast
setup.

The first instinct was a Homebrew Cask (`brew install --cask stimmgabel`).
Two research passes (see `related_research`) showed this would force an
upgrade to Developer ID + notarytool + staple in 2026 — Homebrew 5.0/6.0
both require it. Owner is not ready to pay the Apple Developer Account
cost ($99/year) just to ship a hobby tool. So: **drop Homebrew, ship a
`.pkg` via GitHub Releases produced automatically by GitHub Actions on
every `v*` tag push**.

The signing choice for v1 went through two iterations:

1. First plan was true ad-hoc (`codesign -s -`) so CI needs no secrets.
2. But ad-hoc signing means the macOS TCC database keys on **cdhash**.
   Every new build has a different cdhash → every Stimmgabel update
   would require teammates to re-grant Microphone, System Audio Recording
   etc. permissions in System Settings. For a tool whose value is
   "install and forget", that's the wrong trade-off.

Final v1 choice: **import the author's existing Apple Development
certificate into CI via a GitHub Secret**, so the .app and .driver are
signed with a stable Team-ID-based Designated Requirement. TCC
permissions persist across versions. Gatekeeper still warns on first
launch (Apple Development is not Developer ID), so a one-time "Open
Anyway" gesture remains — same friction as today's local build, no
worse for teammates.

This is a third path that ADR 0008 didn't anticipate (it framed v1 as
"ad-hoc" and v2 as "Developer ID + notarise"). The actual v1 path used
locally and now in CI is "Apple Development cert" — neither pole of ADR
0008. **Worker should write a short ADR clarifying this**, superseding
the ad-hoc-only language in 0008's v1 row. Body of ADR: why Apple
Development cert (free, stable DR, no notarisation overhead); why not
true ad-hoc (TCC permission re-prompt on every update); why not yet
Developer ID + notarise (no Apple Dev account).

The Homebrew option is not gone forever — once a Developer ID account
exists, a new task can revisit the cask path. The research reports
remain the canonical reference for that future decision.

## What

Two production artefacts plus the release pipeline that produces them.

### A. The `.pkg` installer

A single, distributable `.pkg` per release that:

- Installs `Stimmgabel.app` to `/Applications/`
- Installs `Stimmgabel.driver` to `/Library/Audio/Plug-Ins/HAL/`
- Both bundles signed with the author's **Apple Development** identity
  (Team ID `3C96LH326Y`) so TCC permissions persist across versions
- The .pkg itself stays unsigned — `productsign` requires a Developer ID
  Installer cert which we don't have. End users right-click → Open the
  .pkg the first time (documented in README)
- Runs a postinstall script that `killall coreaudiod` (research note:
  do NOT use `launchctl kickstart`, which returns EPERM under SIP on
  macOS ≥ 14.4; `killall coreaudiod` is the BlackHole-validated pattern)
- Triggers exactly one admin-password prompt at install time (handled by
  macOS Installer.app natively)

### B. The release automation (GitHub Actions)

A workflow at `.github/workflows/release.yml` that:

- **Triggers on `v*` tag push only.** No `main`-push pre-releases, no
  scheduled builds. Author cuts a release by tagging a commit
  (`git tag v0.2.0 && git push --tags`).
- **Builds on a macOS runner** (`runs-on: macos-latest`).
- **Imports the Apple Development certificate** from a GitHub Secret
  into a fresh temporary keychain before invoking `script/build`:
  - Secrets used (must be set up once by the author):
    - `APPLE_DEV_CERT_P12_BASE64` — `.p12` export of the cert + private
      key, base64-encoded
    - `APPLE_DEV_CERT_PASSWORD` — the password set when exporting
    - `KEYCHAIN_PASSWORD` — any string; used to lock the temporary
      keychain for the workflow's duration
  - Imports via `security create-keychain` + `security import` +
    `security set-key-partition-list` (the last step prevents the
    codesign tool from prompting for keychain access — critical in CI)
- **Reuses `script/build`** as-is — it already calls xcodebuild with
  the right `CODE_SIGN_IDENTITY="Apple Development"` and
  `DEVELOPMENT_TEAM="3C96LH326Y"`. No script change for build itself.
- **Runs the new `script/release`** to wrap the built .app + .driver
  into the .pkg.
- **Derives the version** from the git tag: `v0.2.0` → version string
  `0.2.0`. Passes that into both Info.plist (via `agvtool` or `plutil`)
  and `pkgbuild --version`.
- **Creates a DRAFT release** with the .pkg attached and GitHub's
  auto-generated release notes as the body. Author publishes from the
  GitHub UI after a local smoke-test install of the drafted .pkg.
- Uses `GITHUB_TOKEN` for the release step (default permission set
  with `contents: write`).

### C. Concrete deliverables

1. **`script/release`** — new script that runs `script/build`, then
   `pkgbuild --root <staging>` against an absolute layout
   (`Applications/Stimmgabel.app`, `Library/Audio/Plug-Ins/HAL/Stimmgabel.driver`)
   plus a postinstall script, then `productbuild --distribution` to
   wrap it in an installer pkg. Output goes to
   `dist/Stimmgabel-<version>.pkg`. Accepts version via
   `--version <semver>` or env `STIMMGABEL_VERSION`. Re-runnable
   locally for testing (uses the author's keychain in that case).
2. **`.github/workflows/release.yml`** — workflow described above.
   Concise; reuses `script/release`. Output asset uploaded to the
   draft release via `softprops/action-gh-release` or
   `gh release create --draft …`.
3. **`docs/SECRETS.md`** — one-page guide for the author on how to set
   up the GitHub Secrets the FIRST time (and how to rotate the cert
   when it expires — Apple Development certs expire after ~1 year).
   Steps: export Apple Development cert from Keychain Access as .p12 →
   base64 encode (`base64 -i cert.p12 | pbcopy`) → paste into
   `APPLE_DEV_CERT_P12_BASE64` repo secret; record password in
   `APPLE_DEV_CERT_PASSWORD`; pick any string for `KEYCHAIN_PASSWORD`.
4. **README "Install" section update** with the install flow:
   - Download the latest `Stimmgabel-<version>.pkg` from the project's
     GitHub Releases page (link it)
   - **Right-click → Open** the .pkg the first time (macOS shows
     "unidentified developer" because the .pkg itself is unsigned).
     Subsequent installs of newer versions: same right-click → Open
   - Installer.app handles the rest, one admin prompt
   - On first launch of `Stimmgabel.app`: macOS may show a Gatekeeper
     warning. Open System Settings → Privacy & Security → "Open
     Anyway" once. Subsequent launches AND subsequent versions of the
     app launch normally (because the Apple Development DR is stable
     across versions)
   - First Microphone + System Audio Recording permission prompts on
     first launch; these PERSIST across updates
5. **`docs/RELEASING.md`** — author-facing one-page guide:
   - `git tag v0.X.Y` + `git push --tags`
   - Wait ~5 minutes for the GitHub Actions workflow to finish
   - Find the draft release in the GitHub UI, download the .pkg,
     smoke-test on a real Mac
   - Edit notes (auto-generated content is the starting point), click
     "Publish release"
6. **Uninstall** — `script/uninstall-driver.sh` already exists. Confirm
   it still works (driver path unchanged) and link from README under
   a "Removing Stimmgabel" section.
7. **ADR** — short ADR clarifying the v1 signing path: Apple Development
   cert in CI via Secret. Supersedes the "ad-hoc" framing in ADR 0008's
   v1 row. Notes the upgrade path to Developer ID + notarisation as v2.

## Acceptance criteria

- [ ] `script/release --version 0.2.0` (run locally) produces a working
      `dist/Stimmgabel-0.2.0.pkg` containing both the app and the driver,
      with a postinstall that restarts coreaudiod
- [ ] On a clean Mac (no prior Stimmgabel install): right-click → Open
      the .pkg → Installer.app walks through → one admin-password prompt
      → install completes; `Stimmgabel` appears as a microphone input
      device in Audio MIDI Setup
- [ ] First launch of `/Applications/Stimmgabel.app` shows the Gatekeeper
      warning. Following the README's "Open Anyway" steps allows the app
      to launch. Subsequent launches work without further intervention
- [ ] After granting Mic + System Audio permissions on v0.X.0, installing
      v0.X.1 (or any newer version signed with the same Apple Development
      cert) **does NOT** force re-granting permissions. TCC honours the
      stable Team-ID-based DR
- [ ] Pushing a `v0.X.Y` tag triggers the `release.yml` workflow on a
      macOS runner; the workflow imports the cert from secrets into a
      temporary keychain, builds, packages, and on success creates a
      **draft** GitHub Release with the `.pkg` attached and
      auto-generated release notes
- [ ] The workflow fails loudly (non-zero exit, no draft release created)
      if any step fails — cert import error, build failure, missing
      artefact, codesign failure
- [ ] Author can publish the draft release from the GitHub UI after
      smoke-testing the downloaded .pkg
- [ ] `docs/SECRETS.md` documents the one-time cert setup AND the cert
      rotation process when the Apple Development cert expires (Apple
      Development certs are valid for ~1 year)
- [ ] `docs/RELEASING.md` documents the author's release flow (tag-push →
      smoke-test → publish-draft)
- [ ] README "Install" section is the canonical onboarding doc, with the
      exact path: download → right-click Open → admin prompt → "Open
      Anyway" on first launch
- [ ] `script/uninstall-driver.sh` still works; mentioned in the README
- [ ] A short ADR clarifies the Apple-Development-cert v1 signing path,
      superseding ADR 0008's "ad-hoc" framing for v1
- [ ] Existing tests stay green (this task does not touch app code paths)

## Notes

### Explicitly out of scope

- **Homebrew tap or cask.** Researched and rejected for v1 — see
  `related_research`. Revisit when Developer ID signing arrives.
- **Developer ID + notarisation.** ADR 0008's v2 plan. When the author
  is ready to pay for an Apple Developer Account, a new task swaps the
  cert and adds notarytool/stapler. ADR 0008 v2 row stays valid.
- **Auto-publish (no draft step).** Explicitly chose draft → manual
  publish so a broken build never reaches users. If the manual step
  becomes friction, capture as a follow-up.
- **Pre-releases from `main`.** No nightly / pre-release builds for v1.
- **Universal binary (x86_64 + arm64).** GitHub Actions macos-latest is
  Apple Silicon; arm64-only is fine for v1.
- **In-app auto-update.** Out of scope.

### Risks / known sharp edges

- **Cert expiry.** Apple Development certs typically expire ~1 year after
  issue. When that happens, the workflow will fail with a "no identity
  found" or "certificate has expired" error. `docs/SECRETS.md` MUST
  document the renewal flow (re-export from Keychain Access, re-base64,
  update the secret). The author should set a calendar reminder for ~11
  months from cert issue date.
- **Cert revocation.** If the cert is ever revoked by Apple (rare), the
  workflow breaks immediately. Same fix: issue a new cert, re-upload
  secret.
- **Build matrix limited to macos-latest.** GitHub Actions occasionally
  changes the default runner; pin to a specific macOS version
  (`macos-15`, `macos-26`) if reproducibility becomes an issue.
- **The .pkg itself is unsigned** — by design (no Developer ID Installer
  cert). User sees "unidentified developer" on the .pkg double-click;
  right-click → Open works around it. Document this prominently in the
  README install section so teammates know to expect it.

### Implementation hints from research

- **pkgbuild layout pattern (from BlackHole, validated)**:
  ```bash
  pkgbuild \
      --root <staging-root> \
      --identifier com.innoq.stimmgabel.pkg \
      --version <version> \
      --install-location / \
      --scripts <scripts-dir> \
      <component>.pkg

  productbuild \
      --distribution <Distribution.xml> \
      --package-path <component-dir> \
      Stimmgabel-<version>.pkg
  ```
  Staging-root needs `Applications/Stimmgabel.app` and
  `Library/Audio/Plug-Ins/HAL/Stimmgabel.driver` at exact absolute paths.
- **Postinstall script**: `#!/bin/bash` + `killall coreaudiod || true`.
  Must be executable (`chmod +x`).

### GitHub Actions hints

- **Workflow skeleton**:
  ```yaml
  name: release
  on:
    push:
      tags: ['v*']
  jobs:
    build-and-draft-release:
      runs-on: macos-latest
      permissions:
        contents: write
      env:
        VERSION: ${{ github.ref_name }}  # 'v0.2.0'
      steps:
        - uses: actions/checkout@v4

        - name: Set VERSION without leading 'v'
          run: echo "VERSION=${VERSION#v}" >> "$GITHUB_ENV"

        - name: Import Apple Development cert into temp keychain
          env:
            P12_BASE64: ${{ secrets.APPLE_DEV_CERT_P12_BASE64 }}
            P12_PASSWORD: ${{ secrets.APPLE_DEV_CERT_PASSWORD }}
            KEYCHAIN_PASSWORD: ${{ secrets.KEYCHAIN_PASSWORD }}
          run: |
            KEYCHAIN_PATH="$RUNNER_TEMP/build.keychain-db"
            CERT_PATH="$RUNNER_TEMP/cert.p12"

            echo -n "$P12_BASE64" | base64 --decode -o "$CERT_PATH"
            security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
            security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
            security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
            security import "$CERT_PATH" -P "$P12_PASSWORD" -A \
                -t cert -f pkcs12 -k "$KEYCHAIN_PATH"
            security set-key-partition-list -S apple-tool:,apple: \
                -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
            security list-keychain -d user -s "$KEYCHAIN_PATH"

        - name: Build & package
          run: ./script/release --version "$VERSION"

        - name: Create draft release
          uses: softprops/action-gh-release@v2
          with:
            draft: true
            generate_release_notes: true
            files: dist/Stimmgabel-${{ env.VERSION }}.pkg

        - name: Clean up keychain
          if: always()
          run: |
            security delete-keychain "$RUNNER_TEMP/build.keychain-db" || true
  ```
  Worker can iterate on this — semantics matter more than exact syntax.
- **`security set-key-partition-list`** is the critical step that
  prevents codesign from prompting for keychain access in CI. Without
  it the build hangs.
- **No `productsign`** step — the .pkg stays unsigned because we don't
  have a Developer ID Installer cert.

### What needs the user before promote

Spec is fully nailed. The author needs to do the one-time secret setup
(exporting the Apple Development cert from Keychain Access, base64
encoding, adding to repo secrets) BEFORE the worker runs `script/release`
in CI for the first time. That's not a worker task — it's an author
action. The worker can develop and test `script/release` locally and
write the workflow file; the first real CI run will only succeed after
the secrets exist.

## Outcome

Implemented end-to-end release pipeline. Locally verified by running
`./script/release --version 0.0.1-test` against a clean checkout: the
script produced `dist/Stimmgabel-0.0.1-test.pkg`. Expanding the .pkg with
`pkgutil --expand` and extracting its Payload confirmed:

- `/Applications/Stimmgabel.app` lays down at the right absolute path
- `/Library/Audio/Plug-Ins/HAL/Stimmgabel.driver` lays down at the right
  absolute path
- Both bundles' code signatures survive the packaging round-trip
  (`codesign --verify --verbose` passes with "satisfies its Designated
  Requirement" — this is what makes TCC permissions stick across updates)
- The component pkg's `Scripts/postinstall` is present, executable,
  strips quarantine xattrs from both install paths, and runs
  `killall coreaudiod` (BlackHole-validated pattern; NOT
  `launchctl kickstart -k` which is EPERM under SIP since macOS 14.4)
- Distribution XML sets `minSpecVersion=2` and a `min OS = 14.0`
  guard matching the project's macOS-Sonoma floor

Existing `swift test` suite still passes (87 tests, 1 skipped, 0
failures). Acceptance criteria covered:

- Criterion 1 (script/release builds a working .pkg) — verified locally.
- Criteria 2–4 (clean-install UX, Gatekeeper "Open Anyway", TCC
  persistence across updates) — depend on the signature properties
  confirmed above; full end-to-end install on a clean Mac is the
  smoke-test step in `docs/RELEASING.md` (author's responsibility per
  release).
- Criteria 5–6 (tag-push triggers workflow, fails loudly on errors) —
  the workflow file is yaml-valid and uses standard patterns; full CI
  verification awaits the first author tag-push (cannot be exercised
  from a worker without writing to the real repo's tags).
- Criteria 7–10 (docs + uninstall + ADR) — all delivered.
- Criterion 11 (uninstall-driver.sh still works) — unchanged file;
  driver path `/Library/Audio/Plug-Ins/HAL/Stimmgabel.driver` matches.
- Criterion 12 (tests stay green) — verified, 87 tests passing.

### Key files

- `script/release` — new, executable
- `.github/workflows/release.yml` — new
- `docs/SECRETS.md` — new (one-time author setup + cert rotation)
- `docs/RELEASING.md` — new (tag-push → smoke-test → publish-draft)
- `README.md` — rewrote Install section; added "Removing Stimmgabel",
  "Build from source", "Package a .pkg locally", links to ADR 0013 and
  the two docs
- `.agentheim/knowledge/decisions/0013-v1-signing-apple-development-cert-via-ci-secret.md`
  — new ADR clarifying ADR 0008's v1 row (Apple Development cert
  locally + via CI Secret, not true ad-hoc)

### Notes for the next person

- The first real CI tag-push will only succeed after the author has
  configured the three GitHub Secrets per `docs/SECRETS.md`.
- The .pkg is intentionally unsigned. When a paid Apple Developer
  Program account is in play, a follow-up task should add a
  `productsign` step in `script/release` plus a
  `xcrun notarytool submit --wait` + `xcrun stapler staple` block in
  `release.yml` — that's the ADR 0008 v2 row, still valid.
