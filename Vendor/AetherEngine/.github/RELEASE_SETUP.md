# Release automation setup

This repo's `.github/workflows/release-dmg.yml` builds, signs, and notarizes a `DemoPlayerMac.dmg` and uploads it as a release asset on every published GitHub Release. To make that work the runner needs access to a Developer ID Application certificate and Apple notarization credentials, which are provided through repository secrets.

This document is the one-time setup. Once the six secrets below are populated the workflow runs automatically on every release.

## Secrets to set

Go to the repo's [Settings → Secrets and variables → Actions → New repository secret](https://github.com/superuser404notfound/AetherEngine/settings/secrets/actions/new) and add each of the six below.

### 1. `DEVELOPER_ID`

The full identity string codesign uses, looking like:

```
Developer ID Application: Your Name (TEAMID0123)
```

Get yours from your local Mac with:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

Copy the entire double-quoted string into the secret value (without the surrounding quotes).

### 2. `APPLE_ID`

The Apple ID email associated with your Developer Account, e.g. `you@example.com`.

### 3. `APPLE_TEAM_ID`

The 10-character team ID (e.g. `ABCD123456`). It's the parenthesised part of the `DEVELOPER_ID` string.

### 4. `APPLE_APP_PASSWORD`

App-specific password from [account.apple.com](https://account.apple.com) → Sign-In and Security → App-Specific Passwords. Format `xxxx-xxxx-xxxx-xxxx`. The one you used locally for `notarytool store-credentials` works; if you don't have it written down, generate a new one labeled "AetherEngine CI" and use that.

### 5. `DEVELOPER_ID_P12_PASSWORD`

A password you pick when exporting the cert (see step 6). Any non-empty string; the workflow only uses it to decrypt the .p12 on the runner. Treat it like any other password.

### 6. `DEVELOPER_ID_P12_BASE64`

The base64-encoded `.p12` export of your Developer ID Application certificate **AND its private key**. The workflow imports this into a temporary keychain on the runner.

To produce it:

1. Open **Keychain Access** → `Anmeldung` keychain → `Meine Zertifikate` tab.
2. Find the entry `Developer ID Application: Your Name (TEAMID0123)` and expand it so you see both the certificate and the private key beneath.
3. Select **both** the certificate and the private key (cmd-click the second one).
4. Right-click → `2 Objekte exportieren…` → set `File Format: Personal Information Exchange (.p12)` → save somewhere temporary, e.g. `~/Desktop/developerid.p12`.
5. Keychain prompts for a password. Use the same value you'll set in secret 5 (`DEVELOPER_ID_P12_PASSWORD`).
6. Base64-encode the file and copy the result to clipboard:

   ```bash
   base64 -i ~/Desktop/developerid.p12 | pbcopy
   ```

7. Paste into the secret value field. Delete the local `.p12` afterwards (`rm ~/Desktop/developerid.p12`), since the secret on GitHub is now the canonical copy.

**Important**: a `.p12` with the private key included is equivalent to handing someone your code-signing identity. The base64 form is treated as a secret by GitHub Actions (masked from logs), and the workflow imports it into a fresh disposable keychain that's torn down at job exit. Don't paste the base64 content into Slack, email, issues, or share it outside the secrets store.

## Smoke-test the workflow

Once all six secrets are set:

1. Make sure a release exists (use the existing `2.0.0` or create a draft tag).
2. Trigger the workflow manually: [Actions](https://github.com/superuser404notfound/AetherEngine/actions) → `Release .dmg` → `Run workflow` → enter the tag → Run.
3. Watch the job. It should reach "Upload .dmg to release" and finish green in 3-6 minutes.
4. Confirm the `.dmg` appears under the release's Assets (or got `--clobber`'d over the existing one if you pointed at `2.0.0`).

After that, every future `gh release create` will trigger this workflow automatically on the `release: published` event. No manual `Scripts/build-dmg.sh` runs needed.

## Rotating credentials

If the Developer ID cert gets revoked or replaced, or the app-specific password is rotated:

1. Export the new cert as a fresh `.p12`, base64-encode, replace `DEVELOPER_ID_P12_BASE64` and `DEVELOPER_ID_P12_PASSWORD`.
2. Generate a fresh app-specific password, replace `APPLE_APP_PASSWORD`.
3. The `DEVELOPER_ID` and `APPLE_TEAM_ID` strings rarely change.
