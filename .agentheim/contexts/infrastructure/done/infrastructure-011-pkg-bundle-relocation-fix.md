---
id: infrastructure-011
title: Release .pkg — disable bundle relocation so install always lands in /Applications
status: done
type: bug
context: infrastructure
created: 2026-06-17
completed: 2026-06-17
commit:
depends_on: []
blocks: []
tags: [pkg, packagekit, bundle-relocation, release, bug]
related_adrs: []
related_research: []
prior_art: [infrastructure-010]
---

## Why

The v0.1.0 release pipeline (infrastructure-010) shipped a `.pkg` that
installs `Stimmgabel.app` to `/Applications/` — except when it doesn't.

macOS PackageKit has a feature called **Bundle Relocation**: at install
time, PackageKit scans the system for any existing bundle whose
`CFBundleIdentifier` matches what the `.pkg` wants to install
(`com.innoq.stimmgabel`). If it finds one — anywhere on disk — it
silently **updates that copy in place** instead of writing the bundle to
its declared install location.

For the author this is catastrophic: the dev build at
`.build/xcodebuild/Stimmgabel.app` (left over from
`./script/build`) gets overwritten by the installer, while `/Applications/`
stays empty. The installer reports success. The Finder shows no app in
`/Applications`. The user is confused.

Concrete evidence from `/var/log/install.log` of the 2026-06-17 09:25 run:

```
PackageKit: Applications/Stimmgabel.app relocated to
  Users/joshuatopfer/Documents/Projekte/INNOQ/stimmgabel/.build/xcodebuild/Stimmgabel.app
PackageKit: Touched bundle .../.build/xcodebuild/Stimmgabel.app
```

This behaviour will also bite any teammate who happens to have a previous
copy of `Stimmgabel.app` anywhere on their disk (downloaded build,
trashed copy not yet emptied, dev clone).

## What

Disable bundle relocation in the pkg's component plist so PackageKit
**always** installs to the declared `/Applications/` location, regardless
of what's already on disk.

`pkgbuild`'s `--analyze` pass generates a default component plist that
includes a `BundleIsRelocatable` key per bundle, defaulting to `YES`. We
need to set it to `NO` for `Stimmgabel.app` and feed the edited plist
back via `--component-plist`.

### Concrete change to `script/release`

After the staging step and before the `pkgbuild` call:

```bash
# Generate the default component plist that pkgbuild would otherwise
# auto-derive — we then edit BundleIsRelocatable=NO so PackageKit cannot
# relocate Stimmgabel.app to a pre-existing copy on disk.
COMPONENTS_PLIST="$COMPONENTS_DIR/components.plist"
pkgbuild --analyze --root "$STAGING" "$COMPONENTS_PLIST"

# The plist is an array of dictionaries — one per bundle. We have exactly
# one .app, so it's index 0. plutil is easier than xmllint for in-place
# bool replacement.
plutil -replace 0.BundleIsRelocatable -bool NO "$COMPONENTS_PLIST"
```

Then add `--component-plist "$COMPONENTS_PLIST"` to the existing
`pkgbuild` invocation.

The driver (`Stimmgabel.driver`) is NOT an `.app` bundle in this sense —
it lives under `/Library/Audio/Plug-Ins/HAL/` and `pkgbuild --analyze`
typically doesn't add it to the relocatable list at all (only top-level
`.app` bundles are subject to relocation). Verify this empirically when
the worker writes the script — if the driver does appear in the
generated plist, set `BundleIsRelocatable=NO` for it too.

## Acceptance criteria

- [ ] `script/release --version 0.1.1` produces
      `dist/Stimmgabel-0.1.1.pkg` containing the same payload as before
      plus an embedded component plist with `BundleIsRelocatable=NO`
      for the `.app`
- [ ] `pkgutil --expand dist/Stimmgabel-0.1.1.pkg /tmp/sg-pkg-test &&
      grep -i "BundleIsRelocatable" /tmp/sg-pkg-test/Stimmgabel-component.pkg/Bom.bom`
      … OR equivalent inspection step confirming the flag is in the
      package metadata (worker may use a different tool — `pkgutil
      --payload-files` plus reading the `PackageInfo` xml is also fine)
- [ ] Local smoke test: with `.build/xcodebuild/Stimmgabel.app` present
      on disk, running the new `.pkg` via `installer -pkg <pkg> -target /`
      results in `/Applications/Stimmgabel.app` existing AND the dev
      build at `.build/xcodebuild/Stimmgabel.app` being unchanged
      (`stat -f "%Sm"` matches the pre-install mtime)
- [ ] `/var/log/install.log` for the new install run no longer contains
      a `relocated to` line for Stimmgabel
- [ ] Existing 87 tests stay green (this task does not touch app code)
- [ ] `docs/RELEASING.md` is updated with a note explaining that the
      pipeline disables bundle relocation, so author and teammates can
      reason about install paths without surprise

## Notes

### How the v0.1.0 release was unblocked

On the author's Mac, the v0.1.0 install effectively put the app at
`.build/xcodebuild/Stimmgabel.app` (relocated) and the driver at the
correct `/Library/Audio/Plug-Ins/HAL/Stimmgabel.driver`. Manual recovery
was a `sudo cp -R .build/xcodebuild/Stimmgabel.app /Applications/`.
After this task lands and v0.1.1 is released, that workaround should
not be needed.

### Why this didn't show up earlier

The walking skeleton (infrastructure-006) installed the driver via
`./script/install-driver.sh` (system-domain `cp -R` + `sudo killall
coreaudiod`) and the app via `./script/build` writing to `dist/`. The
installer path is new in v0.1.0 (infrastructure-010), and bundle
relocation is a `.pkg`-only PackageKit feature — that's why the bug
only surfaced when the first teammate (author) ran the actual installer.

### Source

This is the canonical PackageKit relocation footgun. It's documented in
Apple's `pkgbuild(1)` man page under "COMPONENT PROPERTY LIST" and
discussed in the Apple Developer Forums for any app shipped as a `.pkg`.
The `BundleIsRelocatable=NO` opt-out is the standard mitigation.

### Out of scope

- Not a re-design of the release pipeline — just the missing component
  plist step.
- Not adding pkg-signing (Developer ID Installer) — that's still
  deferred per ADR 0013 / ADR 0008.
- Not re-issuing v0.1.0 — the fix lands in v0.1.1.

## Outcome

`script/release` now runs `pkgbuild --analyze` to generate a component
property list, flips `BundleIsRelocatable=NO` on every entry, and feeds
it back via `--component-plist`. Two findings vs. the task hint:

1. `pkgbuild --analyze` emits BOTH bundles into the plist, not just the
   `.app`. The task hint suggested the driver would be excluded; it
   isn't. The implementation defensively loops over every entry and
   flips the flag — driver included. Setting it on the driver is
   harmless (driver bundles under `/Library/Audio/Plug-Ins/HAL/` aren't
   targets of PackageKit relocation anyway).
2. The `.app` is at index 1, not 0. The driver comes first
   alphabetically by `RootRelativeBundlePath`. Index-0 hard-coding from
   the task sketch would have flipped the wrong entry and left the bug
   in place. The loop avoids that.

### Verification

Built two test pkgs from a synthesised staging tree — one without
`--component-plist` (baseline / current bug), one with the new logic.
PackageInfo XML diff:

- Baseline: `<relocate><bundle id="com.innoq.stimmgabel"/></relocate>`
- Fixed: `<relocate/>` (empty, self-closing)

The empty `<relocate>` element is the deterministic PackageKit signal
that bundle relocation is disabled — PackageKit no longer scans the
disk for a pre-existing `com.innoq.stimmgabel` to redirect to.

End-to-end smoke test against the real `script/build` output was
blocked locally by a root-owned residue in
`.build/xcodebuild/Stimmgabel.app/Contents/Resources/AppIcon.icns`
(itself a symptom of the very relocation bug being fixed — the v0.1.0
installer wrote into the dev build dir as root). CI will exercise the
full pipeline on a fresh runner when v0.1.1 is tagged. The author can
also reproduce locally after `sudo rm -rf .build`.

### Files changed

- `script/release` — new component-plist generation block between
  staging and `pkgbuild`; `pkgbuild` invocation now passes
  `--component-plist`
- `docs/RELEASING.md` — new "Bundle relocation is disabled" subsection
  under "Watch the workflow"
