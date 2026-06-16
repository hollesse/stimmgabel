# GitHub Secrets — one-time setup & cert rotation

The `release.yml` GitHub Actions workflow needs three repository secrets to
sign the .app and .driver inside the CI runner. This is the only manual setup
required before the first `v*` tag push will produce a usable release.

> **Whose responsibility:** the repo owner / author. Teammates installing
> the .pkg do not need any of this.

## The three secrets

| Secret name                 | Value                                            |
| --------------------------- | ------------------------------------------------ |
| `APPLE_DEV_CERT_P12_BASE64` | base64 of a `.p12` export of the cert + private key |
| `APPLE_DEV_CERT_PASSWORD`   | the password set during the `.p12` export        |
| `KEYCHAIN_PASSWORD`         | any string; locks the temporary CI keychain      |

## First-time setup (≈ 5 minutes)

### 1. Export the Apple Development cert as `.p12`

1. Open **Keychain Access** (Applications → Utilities).
2. Side panel → **login** keychain → **My Certificates** category.
3. Locate the entry named **Apple Development: <Your Name> (3C96LH326Y)**.
   Expand it; the private key must be present underneath. If there is no
   private key, you cannot export — you need to issue the cert on this Mac
   (Xcode → Settings → Accounts → Manage Certificates → + → Apple
   Development).
4. **Select both rows** (the cert and the private key), right-click →
   **Export 2 items…**.
5. File format: **Personal Information Exchange (.p12)**.
6. Save as `apple-dev-cert.p12` somewhere temporary.
7. Set a password when prompted. This is your `APPLE_DEV_CERT_PASSWORD`.
   Use the system password generator or any string you'll remember
   long enough to paste it into GitHub.

### 2. Base64-encode the `.p12`

In a Terminal:

```sh
base64 -i /path/to/apple-dev-cert.p12 | pbcopy
```

The base64-encoded blob is now on the clipboard.

### 3. Add the three secrets to the GitHub repo

GitHub → repo → **Settings** → **Secrets and variables** → **Actions** →
**New repository secret**. Add each of these:

| Name                        | Value                                                |
| --------------------------- | ---------------------------------------------------- |
| `APPLE_DEV_CERT_P12_BASE64` | paste from clipboard (the base64 blob)               |
| `APPLE_DEV_CERT_PASSWORD`   | the password you set during the .p12 export         |
| `KEYCHAIN_PASSWORD`         | any string (e.g. a fresh 1Password-generated value) |

### 4. Clean up local files

```sh
rm /path/to/apple-dev-cert.p12
```

The clipboard will also be cleared automatically after a while; if you
want to be sure: `pbcopy < /dev/null`.

### 5. Verify

Push a throwaway tag against a branch to test the workflow without
publishing anything user-visible:

```sh
git tag v0.0.0-test
git push --tags
```

Watch the workflow on the **Actions** tab. The "Import Apple Development
cert into temporary keychain" step should succeed; the "Sanity check"
line should find the **Apple Development** identity; the workflow should
finish by drafting a release. After verifying, delete the draft release
and delete the test tag (`git push --delete origin v0.0.0-test &&
git tag -d v0.0.0-test`).

## Cert rotation (do this once a year)

Apple Development certificates are valid for **~365 days**. When the cert
expires, the workflow will fail with one of:

- `error: No signing certificate "Apple Development" found`
- `error: <cert subject>: certificate has expired`

To rotate:

1. **Set a calendar reminder for ~11 months from cert issue date.** Check
   the cert's expiry in Keychain Access (double-click the cert → look at
   the "Expires" row) and put the reminder in your calendar at that date
   minus a month.
2. **Issue a fresh Apple Development cert.** Xcode → Settings → Accounts
   → select your Apple ID → **Manage Certificates** → **+** → **Apple
   Development**.
3. Re-export as `.p12` (steps 1–2 above).
4. Re-base64 and update the **`APPLE_DEV_CERT_P12_BASE64`** secret in
   GitHub. You can keep the old `APPLE_DEV_CERT_PASSWORD` if you reuse
   the same export password; otherwise update it too.
5. **Trigger a smoke release** the same way as step 5 of setup, to
   confirm the new cert imports cleanly. Then delete the test tag.

## Cert revocation (rare)

Same fix as rotation: revoke the bad cert in Apple's Developer portal /
Keychain Access, issue a new one, re-export, re-base64, update the secret.

## Cost

This whole flow uses an **Apple Development** certificate, which is free
with any Apple ID — **no Apple Developer Program membership ($99/year) is
required**. A future upgrade to **Developer ID + notarisation** (so the
.pkg can be double-clicked without the right-click → Open dance) does
require a paid membership; that's deferred to v2.
