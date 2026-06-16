# Releasing Stimmgabel

How the author cuts a new release. Audience: the repo owner. Teammates
installing Stimmgabel should read the top-level [README](../README.md)
instead.

## TL;DR

```sh
git tag v0.X.Y
git push --tags
# wait ~5 min, smoke-test the draft .pkg, click "Publish release" on GitHub
```

## Prerequisites (one-time)

- GitHub Secrets are configured — see [SECRETS.md](SECRETS.md). Without
  them the workflow fails at the cert-import step.
- You have push access to the repository.

## The release flow

### 1. Pick a version

Stimmgabel uses semver. Bump:

- **patch** (`v0.1.0` → `v0.1.1`) for bug fixes.
- **minor** (`v0.1.1` → `v0.2.0`) for new features that don't break
  install/uninstall.
- **major** (`v0.x.y` → `v1.0.0`) when the install layout or driver
  identifier changes.

### 2. Tag and push

```sh
# from main, with a clean working tree:
git tag v0.X.Y
git push --tags
```

That's the only manual step. The push triggers
`.github/workflows/release.yml` automatically.

### 3. Watch the workflow

GitHub → repo → **Actions** tab → the most recent **release** run.
Roughly 5 minutes end-to-end on a `macos-latest` runner.

The workflow:

1. Imports the Apple Development cert into a temporary keychain.
2. Runs `./script/release --version X.Y.Z`, which calls `./script/build`
   then `pkgbuild` + `productbuild`.
3. Attaches `dist/Stimmgabel-X.Y.Z.pkg` to a **DRAFT** GitHub Release.
4. Cleans up the keychain.

If anything fails, the run shows the failed step in red. Common failures:

- **Cert import error** — `APPLE_DEV_CERT_P12_BASE64` is stale (expired
  cert). Rotate per [SECRETS.md](SECRETS.md#cert-rotation-do-this-once-a-year).
- **codesign failure** — usually a transient `macos-latest` runner
  hiccup; re-run the workflow first before debugging.
- **Missing `dist/Stimmgabel-*.pkg`** — `./script/release` failed
  earlier; scroll up to find the real error.

### 4. Smoke-test the draft

On a Mac (your dev machine is fine):

1. GitHub → repo → **Releases** → the new draft release → download
   `Stimmgabel-X.Y.Z.pkg`.
2. Uninstall any previous Stimmgabel driver to test the clean path:
   `./script/uninstall-driver.sh` (or skip if you want to test the
   upgrade path instead).
3. Right-click → **Open** the downloaded .pkg. macOS will warn about an
   unidentified developer; click **Open** in the warning dialog.
4. Walk through Installer.app. Enter your admin password when prompted.
5. After install: open **Audio MIDI Setup** and confirm `Stimmgabel`
   appears as an input device.
6. Launch `/Applications/Stimmgabel.app`. On first launch you may need
   System Settings → Privacy & Security → **Open Anyway** for the .app.
   The menu-bar icon appears; click it; confirm the app is running.

If anything is broken: **don't publish the draft**. Delete it, fix the
issue on `main`, cut a fresh tag (e.g. `v0.X.Y+1`).

### 5. Publish the release

When the smoke-test passes:

1. GitHub → repo → **Releases** → the draft → **Edit**.
2. Review the auto-generated release notes. They are based on the merged
   PRs since the previous tag. Tighten or expand as needed.
3. Click **Publish release**.

Teammates can now download the .pkg from the public Releases page. The
README links to it.

## Why a draft step?

So a broken build never reaches users. If we ever decide the draft step
itself is friction, it can be turned into auto-publish via a one-line
workflow change (`draft: true` → `draft: false`).

## What we are NOT doing in v1

- **Auto-publish** (no manual gate) — see above.
- **Nightly / pre-release builds** from `main` — only `v*` tags trigger.
- **`productsign` of the .pkg** — requires a Developer ID Installer cert
  we don't have. The .pkg stays unsigned; teammates right-click → Open.
- **Notarisation** — requires Apple Developer Program membership
  ($99/year). When that arrives, this doc + the workflow + ADR 0008's v2
  row will be updated as a single follow-up task.
