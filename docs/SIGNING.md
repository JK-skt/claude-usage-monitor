# Code Signing & Notarization

Ad-hoc builds trigger a Gatekeeper warning on first open. To ship a build that opens
cleanly, sign it with a **Developer ID Application** certificate and **notarize** it with
Apple. This project's scripts do this end-to-end once you have the credentials.

> Requires a paid **Apple Developer Program** membership ($99/yr). The tooling
> (`codesign`, `notarytool`, `stapler`) ships with the Command Line Tools — no full
> Xcode needed.

## One-time setup

### 1. Create a Developer ID Application certificate
Xcode → Settings → Accounts → *Manage Certificates* → **+** → *Developer ID Application*
(or create it in the Apple Developer portal and download the `.cer` + install the `.p12`).
Confirm it's in your keychain:

```bash
security find-identity -v -p codesigning
#   1) ABCD… "Developer ID Application: Your Name (TEAMID)"
```

### 2. Create an app-specific password
At <https://appleid.apple.com> → Sign-In & Security → *App-Specific Passwords*.

### 3. Store notarization credentials (one time)
```bash
xcrun notarytool store-credentials "claude-usage-monitor-notary" \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "abcd-efgh-ijkl-mnop"     # the app-specific password
```

## Build a signed + notarized release

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
VERSION=0.1.0 \
scripts/release.sh
```

This runs: `build-app.sh` (Developer ID signature + **hardened runtime** + secure
timestamp) → `make-dmg.sh` → `notarize.sh` (`notarytool submit --wait` + `stapler
staple`). The resulting `dist/ClaudeUsageMonitor-<version>.dmg` opens without a Gatekeeper
warning, even offline (the ticket is stapled).

### Individual steps
```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-app.sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/make-dmg.sh
scripts/notarize.sh dist/ClaudeUsageMonitor-0.1.0.dmg
```

## Verify

```bash
codesign --verify --strict --verbose=2 dist/ClaudeUsageMonitor.app
spctl -a -vv dist/ClaudeUsageMonitor.app          # → accepted, source=Notarized Developer ID
xcrun stapler validate dist/ClaudeUsageMonitor-0.1.0.dmg
```

## CI (GitHub Actions)

`.github/workflows/release.yml` signs + notarizes automatically when you push a `v*` tag.
It needs these repository **secrets**:

| Secret | What |
|--------|------|
| `MACOS_CERT_P12_BASE64` | `base64 -i DeveloperID.p12` of the exported cert |
| `MACOS_CERT_PASSWORD` | password used when exporting the `.p12` |
| `APPLE_ID` | your Apple ID email |
| `APPLE_TEAM_ID` | your 10-char Team ID |
| `APPLE_APP_PASSWORD` | the app-specific password |

Export the `.p12` from Keychain Access (right-click the Developer ID Application identity →
Export), then:

```bash
base64 -i DeveloperID.p12 | pbcopy   # paste into the MACOS_CERT_P12_BASE64 secret
```
