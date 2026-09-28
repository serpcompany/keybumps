# Direct update operations

Keybumps uses one Sparkle 2 controller owned by the app shell. Feature modules do not import Sparkle. The standard Sparkle window presents release notes and install choices; Keybumps mirrors structural status in General and its menu. Update requests never contain searches, filenames, Clipboard History, Dictation content, recordings, Keyboard Shortcutter history, license data, or customer identity.

## Configuration

Release archives must be built with both settings below. They are public configuration, not secrets. The project also enables Sparkle's signed-feed and verify-before-extraction requirements, so `generate_appcast` signs both the archive enclosure and the feed itself.

- Production: `KEYBUMPS_UPDATE_FEED_URL=https://updates.keybumps.app/appcast.xml`
- Staging: `KEYBUMPS_UPDATE_FEED_URL=https://updates.keybumps.app/staging/appcast.xml`
- `KEYBUMPS_UPDATE_PUBLIC_KEY=<Sparkle Ed25519 public key>`

The `updates.keybumps.app` origin is the only accepted release origin. DNS/HTTPS provisioning and the initial empty feed are external gates; no Keybumps release may be built or published until both paths are live and byte verification passes. The repository and production private key remain private.

An absent or invalid configuration disables the updater truthfully. Debug and tests never use the production feed by default. A Debug fixture can use `KEYBUMPS_UPDATE_FIXTURE_FEED_URL=http://127.0.0.1:<port>/appcast.xml`, but its public key must still be injected at build time.

Generate the production key once with Sparkle's `generate_keys --account keybumps-production`. Keep the private key only in the operator Keychain/secret store and an encrypted, access-controlled recovery backup. Never commit, print, ship, or upload it. Losing it prevents existing installations from trusting ordinary future updates; key rotation must follow Sparkle's documented migration procedure.

## Hosting and publication boundary

The remote repository is `serpcompany/keybumps`. The update origin is the `keybumps-updates` R2 bucket; see [`cloudflare.md`](cloudflare.md) for the inventory, object layout, and access. Release preparation produces immutable ZIP/DMG assets, release notes, a signed appcast, and `latest.json`; `scripts/publish-release.sh` performs the owner-authorized upload. Upload assets and notes first and publish the signed appcast pointer last, together with `latest.json`.

Historical SuperMac Pages artifacts belong to a different bundle identity and trust chain. Never copy or recreate that feed as a Keybumps update bridge; existing SuperMac testers must install Keybumps manually.

## Release sequence

The normal entry point is `scripts/build-update-release.sh`. It refuses a reused build or existing output directory, archives and exports with Developer ID, submits through the authenticated `asc notarization` API, staples, packages ZIP and DMG artifacts, generates and validates the signed appcast, and creates separate `publication/assets` and `publication/publish-last` directories. It does not upload anything.

1. Increase `CFBundleVersion` above every previously published build and set the customer-facing semantic `MARKETING_VERSION`.
2. Archive arm64 Keybumps with the stable `com.serp.keybumps` bundle ID, the production feed URL, and the matching public key.
3. Export with Developer ID, notarize, staple, and package the stapled app as the Sparkle update archive and DMG.
4. Put the update archive and matching `.md` release notes in a clean staging directory.
5. Run Sparkle's `generate_appcast` through `scripts/generate-staged-appcast.sh`. The private key stays in Keychain.
6. Run `scripts/validate-update-release.sh` with both the feed URL embedded in the candidate app and the appcast URL currently advertising it. These are normally identical; staged promotion may validate a production-configured candidate advertised from the staging channel. The validator uses Sparkle's official tools and the selected Keychain account to verify that the app's public key matches, then cryptographically verifies the signed feed, archive, and linked release notes. It also fails closed on malformed XML, checksum/size drift, identity/version/feed/compatibility, Apple signature, Gatekeeper, notarization-ticket failures, or appcast assets outside the publication directory. The fixture-only trust-skip option is never valid release evidence.
7. Run `scripts/publish-release.sh <output-directory> staging` (dry run) to review the plan, then, with owner authorization, add `--publish`. It uploads immutable assets to `releases/<build>/` first (refusing to overwrite different bytes), verifies each public copy byte for byte, and only then publishes the pointer (`staging/appcast.xml`). `scripts/verify-update-publication.sh … --verify-live` remains available for an independent byte check.
8. Install build N in `/Applications`, advertise N+1 on the staged feed, and verify check, download, signature validation, restart, exact N+1 version, and retained non-private fixture preferences. Repeat with active Dictation and confirm restart is refused until Dictation is idle.
9. Corrupt a copy of the signed archive without regenerating the appcast and confirm Sparkle rejects it. Never weaken verification for this test.
10. Promote to production with `scripts/publish-release.sh <output-directory> production --publish` (owner-authorized). The immutable assets are already published and are skipped after byte verification; it then publishes `appcast.xml` and `latest.json` last and verifies both.
11. Publish `publication/publish-last/latest.json` beside the production `appcast.xml` (`https://updates.keybumps.app/latest.json`) at the same time as the appcast. `scripts/write-latest-release-pointer.sh` derives it from the validated appcast: `version`, `build`, `dmgURL` (the DMG beside the archive enclosure), and the DMG `sha256`. It refuses a foreign origin, a version or build mismatch, or a malformed checksum. The keybumps.app download page (`serpcompany/keybumps.app`) reads this file, so a release needs no website edit.

## Release in CI

Releases are built and published by the manually triggered **Release Keybumps** workflow (`.github/workflows/release.yml`) on a macOS runner. Merging to `main` never releases. Run it from Actions → Release Keybumps with:

- `version`: marketing version. `docs/releases/v<version>.md` must exist on the chosen ref.
- `build`: optional. Defaults to the live production build + 1 and must exceed it.
- `channel`: `staging` or `production` (which appcast pointer to publish).
- `publish`: off builds, signs, notarizes, packages, validates, previews publication, and keeps the `publication/` files as a workflow artifact for 90 days. On also runs `scripts/publish-release.sh --publish`.

The workflow uses a temporary keychain for the Developer ID identity and the Sparkle key, pins Sparkle's tools by SHA-256, and fails early if the Sparkle private key doesn't match the public key embedded in Keybumps. The build uses `KEYBUMPS_MANUAL_SIGNING=1` (explicit Developer ID signing via `scripts/ExportOptions-DeveloperID-Manual.plist`); local builds keep automatic signing.

Repository secrets (Settings → Secrets and variables → Actions). The owner creates these; never paste their values into chat, issues, or logs:

| Secret | Contents |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_P12` | Base64 of a `.p12` exported from Keychain Access containing the **Developer ID Application: … (847HR8U8D9)** certificate and its private key (`base64 -i cert.p12 \| pbcopy`) |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | The `.p12` export password |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY` | App Store Connect API key used by `asc notarization`; `ASC_PRIVATE_KEY` is the full `.p8` contents |
| `SPARKLE_PRIVATE_KEY` | The Sparkle EdDSA private key (`generate_keys --account <account> -x key.txt` on the Mac that holds it; delete the file afterwards) |
| `CLOUDFLARE_R2_TOKEN` | Cloudflare API token with Workers R2 Storage: Edit on `keybumps-updates` (see [`cloudflare.md`](cloudflare.md)) |

**Check release credentials** (`.github/workflows/release-credentials.yml`) is a read-only workflow that lists which secrets are set and verifies the R2 token can read `keybumps-updates`. Both workflows use the `release` GitHub environment, where the owner can require approval before any run.

## Local fixture harness

Resolve packages once so Sparkle's `bin/generate_keys` and `bin/generate_appcast` tools are available. Use a dedicated `keybumps-staged` Keychain account; it is not the production key. Build harmless N and N+1 apps with increasing build numbers and the staged public key, package N+1, add matching release notes, and generate the feed:

```sh
scripts/generate-staged-appcast.sh /absolute/path/to/fixture-releases http://127.0.0.1:8765 /absolute/path/to/Sparkle/bin keybumps-staged
scripts/serve-update-fixture.sh /absolute/path/to/fixture-releases 8765
scripts/verify-update-publication.sh /absolute/path/to/fixture-releases/appcast.xml /absolute/path/to/fixture-releases/Keybumps.zip /absolute/path/to/fixture-releases/Keybumps.md http://127.0.0.1:8765/appcast.xml --verify-live
```

Build N with the staged public key, launch it with `KEYBUMPS_UPDATE_FIXTURE_FEED_URL=http://127.0.0.1:8765/appcast.xml`, and exercise the standard Sparkle flow. Local fixture proof is separate from Developer ID/notarized staged acceptance; only the latter is release evidence.

Automated tests prove loopback-only configuration, served-feed parsing, publication byte equivalence, appcast structure, cryptographic tooling, and deterministic app-shell states. Sparkle's actual replacement of an installed application bundle cannot be faithfully simulated from the unit-test host: the remaining live gate is an installed, Developer ID-signed and notarized N→N+1 run from `/Applications`, including Dictation deferral and tamper rejection.
