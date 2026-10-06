# Direct update operations

Keybumps uses one Sparkle 2 controller owned by the app shell. Feature modules do not import Sparkle. The standard Sparkle window presents release notes and install choices; Keybumps mirrors structural status in General and its menu. Update requests never contain searches, filenames, Clipboard History, Dictation content, recordings, Shortcut Coach history, license data, or customer identity.

## Configuration

Release archives must be built with both settings below. They are public configuration, not secrets. The project also enables Sparkle's signed-feed and verify-before-extraction requirements, so `generate_appcast` signs both the archive enclosure and the feed itself.

- Production: `KEYBUMPS_UPDATE_FEED_URL=https://updates.keybumps.app/appcast.xml`
- Staging: `KEYBUMPS_UPDATE_FEED_URL=https://updates.keybumps.app/staging/appcast.xml`
- `KEYBUMPS_UPDATE_PUBLIC_KEY=<Sparkle Ed25519 public key>`

The `updates.keybumps.app` origin is the only accepted release origin. DNS/HTTPS provisioning and the initial empty feed are external gates; no Keybumps release may be built or published until both paths are live and byte verification passes. The repository and production private key remain private.

An absent or invalid configuration disables the updater truthfully. Debug and tests never use the production feed by default. A Debug fixture can use `KEYBUMPS_UPDATE_FIXTURE_FEED_URL=http://127.0.0.1:<port>/appcast.xml`, but its public key must still be injected at build time.

Generate the production key once with Sparkle's `generate_keys --account keybumps-production`. Keep the private key only in the operator Keychain/secret store and an encrypted, access-controlled recovery backup. Never commit, print, ship, or upload it. Losing it prevents existing installations from trusting ordinary future updates; key rotation must follow Sparkle's documented migration procedure.

## Hosting and publication boundary

The remote repository is `serpcompany/keybumps`. The update origin is the `keybumps-updates` R2 bucket; see [`cloudflare.md`](cloudflare.md) for the inventory, object layout, and access. Release preparation produces immutable ZIP/DMG assets, release notes, a signed appcast, and `latest.json`; `apps/macos/scripts/publish-release.sh` performs the owner-authorized upload. Upload assets and notes first and publish the signed appcast pointer last, together with `latest.json`.

Historical SuperMac Pages artifacts belong to a different bundle identity and trust chain. Never copy or recreate that feed as a Keybumps update bridge; existing SuperMac testers must install Keybumps manually.

## Release sequence

The normal entry point is `apps/macos/scripts/build-update-release.sh`. It refuses a reused build or existing output directory, archives and exports with Developer ID, submits through the authenticated `asc notarization` API, staples, packages ZIP and DMG artifacts, generates and validates the signed appcast, and creates separate `publication/assets` and `publication/publish-last` directories. It does not upload anything.

Run it from a Git checkout. It reads `docs/releases/v<version>.md` from the repository root (`git rev-parse --show-toplevel`), so from a `git archive` export or a tarball it stops with exit 66 before building.

1. Increase `CFBundleVersion` above every previously published build and set the customer-facing semantic `MARKETING_VERSION`.
2. Archive arm64 Keybumps with the stable `com.serp.keybumps` bundle ID, the production feed URL, and the matching public key.
3. Export with Developer ID, notarize, staple, and package the stapled app as the Sparkle update archive and DMG.
4. Put the update archive and matching `.md` release notes in a clean staging directory.
5. Run Sparkle's `generate_appcast` through `apps/macos/scripts/generate-staged-appcast.sh`. The private key stays in Keychain.
6. Run `apps/macos/scripts/validate-update-release.sh` with both the feed URL embedded in the candidate app and the appcast URL currently advertising it. These are normally identical; staged promotion may validate a production-configured candidate advertised from the staging channel. The validator uses Sparkle's official tools and the selected Keychain account to verify that the app's public key matches, then cryptographically verifies the signed feed, archive, and linked release notes. It also fails closed on malformed XML, checksum/size drift, identity/version/feed/compatibility, Apple signature, Gatekeeper, notarization-ticket failures, or appcast assets outside the publication directory. The owner-authorized `--signed-not-notarized` mode (step 5 of Release in CI) skips only the Gatekeeper and notarization-ticket checks and instead requires the Keybumps Developer ID Application signature. The fixture-only trust-skip option is never valid release evidence. In CI, `KEYBUMPS_SPARKLE_KEY_FILE` points at a temporary copy of the private key (imported into the keychain account first, deleted right after the build step): `generate_appcast` and `sign_update` read it with `--ed-key-file`, because reading a keychain item created by `generate_keys` shows an access prompt that hangs a headless runner. Local runs use the keychain account.
7. Run `apps/macos/scripts/publish-release.sh <output-directory> staging` (dry run) to review the plan, then, with owner authorization, add `--publish`. It uploads immutable assets to `releases/<build>/` first (refusing to overwrite different bytes), verifies each uploaded object byte for byte from the R2 bucket (CI runners are blocked from the public host by Bot Fight Mode), and only then publishes the pointer (`staging/appcast.xml`). `apps/macos/scripts/verify-update-publication.sh … --verify-live` remains available for an independent byte check.
8. Install build N in `/Applications`, advertise N+1 on the staged feed, and verify check, download, signature validation, restart, exact N+1 version, and retained non-private fixture preferences. Repeat with active Dictation and confirm restart is refused until Dictation is idle.
9. Corrupt a copy of the signed archive without regenerating the appcast and confirm Sparkle rejects it. Never weaken verification for this test.
10. Promote to production with `apps/macos/scripts/publish-release.sh <output-directory> production --publish` (owner-authorized). The immutable assets are already published and are skipped after byte verification; it then publishes `appcast.xml` and `latest.json` last and verifies both.
11. Publish `publication/publish-last/latest.json` beside the production `appcast.xml` (`https://updates.keybumps.app/latest.json`) at the same time as the appcast. `apps/macos/scripts/write-latest-release-pointer.sh` derives it from the validated appcast: `version`, `build`, `dmgURL` (the DMG beside the archive enclosure), and the DMG `sha256`. It refuses a foreign origin, a version or build mismatch, or a malformed checksum. The website (`apps/web/`) reads this file for every Download button and for the `/download/` redirect, so a release needs no website edit.

## Release in CI

Releases are cut by [release-please](https://github.com/googleapis/release-please) and built in CI. Nobody types versions or tags.

1. Merge ordinary PRs to `main` with Conventional Commit titles. `feat:` and `fix:` (plus `perf:` and `refactor:`) become user-facing notes; `docs:`, `test:`, `build:`, `ci:`, and `chore:` stay out.
2. The **Release Please** workflow keeps one open PR titled `release: Keybumps <next version>`. It bumps `version.txt` and `.release-please-manifest.json` and writes `CHANGELOG.md`. Beta versions count up (`0.0.3-beta.4` → `beta.5`). To start a new line, add `Release-As: 0.1.0` to a commit body. Edit the changelog text in that PR if needed.
3. Merging the release PR tags `v<version>`, creates the GitHub Release, and calls **Release Keybumps** (`.github/workflows/release.yml`):
   - `build` (macOS, `release` environment): turns the `CHANGELOG.md` section into `docs/releases/v<version>.md` via `apps/macos/scripts/write-release-notes.sh` (a hand-written file for that version wins); sets the build number to the live production build + 1; builds, signs, notarizes, packages, and validates; keeps the `publication/` artifact for 90 days; publishes to **staging**.
   - `production` (`production` environment): after approval, publishes `appcast.xml` and `latest.json`, which updates in-app updates and keybumps.app/download.
4. Release Keybumps can also be run manually from Actions. It takes a version, an optional build number, and `publish` (off = build and notarize only), plus `notarize`.
5. **Signed but not notarized (interim only).** While notarization is unavailable, the owner may authorize a release that is Developer ID-signed and strictly signature-checked but not notarized: set the repository variable `KEYBUMPS_NOTARIZE=false` (used when the release PR merges) or turn off `notarize` in a manual run. The build skips the notary submission and the Gatekeeper and staple checks, and the release notes must tell customers to use **Open Anyway** on first launch. Delete the variable as soon as notarization works again; the next release is notarized, and existing installs update to it normally.

The owner should require reviewers on the `production` environment (Settings → Environments). Without that, production publishes right after staging. Release Please needs **Allow GitHub Actions to create and approve pull requests** enabled (Settings → Actions → General) to open its PR.

The workflow runs from the repository root, where `CHANGELOG.md` and `docs/releases/` stay, and calls the scripts in the app folder named by its `APP_DIR` (`apps/macos`). It uses a temporary keychain for the Developer ID identity and the Sparkle key, pins Sparkle's tools by SHA-256, and fails early if the Sparkle private key doesn't match the public key embedded in Keybumps. The build uses `KEYBUMPS_MANUAL_SIGNING=1` (explicit Developer ID signing via `apps/macos/scripts/ExportOptions-DeveloperID-Manual.plist`); local builds keep automatic signing.

Repository secrets (Settings → Secrets and variables → Actions). The owner creates these; never paste their values into chat, issues, or logs:

| Secret | Contents |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_P12` | Base64 of a `.p12` exported from Keychain Access containing the **Developer ID Application: … (W3GXL2NQQP)** certificate (team: ADR 0005) and its private key (`base64 -i cert.p12 \| pbcopy`) |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | The `.p12` export password |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY` | App Store Connect API key used by `asc notarization`; `ASC_PRIVATE_KEY` is the full `.p8` contents |
| `SPARKLE_PRIVATE_KEY` | The Sparkle EdDSA private key (`generate_keys --account <account> -x key.txt` on the Mac that holds it; delete the file afterwards) |
| `CLOUDFLARE_R2_TOKEN` | Cloudflare API token with Workers R2 Storage: Edit on `keybumps-updates` (see [`cloudflare.md`](cloudflare.md)) |
| `SENTRY_AUTH_TOKEN` | Optional. A Sentry organization auth token for `serpcompany` that can upload debug files, so crash reports name Keybumps's code (ADR 0007). Without it, or if the upload fails, the release still ships with a warning. `build-qa-candidate.sh` uploads QA candidates' symbols too when it's set in your shell |

**Check release credentials** (`.github/workflows/release-credentials.yml`) is a read-only workflow that lists which secrets are set and verifies the R2 token can read `keybumps-updates`. Both workflows use the `release` GitHub environment, where the owner can require approval before any run.

## Local fixture harness

Resolve packages once so Sparkle's `bin/generate_keys` and `bin/generate_appcast` tools are available. Use a dedicated `keybumps-staged` Keychain account; it is not the production key. Build harmless N and N+1 apps with increasing build numbers and the staged public key, package N+1, add matching release notes, and generate the feed:

```sh
apps/macos/scripts/generate-staged-appcast.sh /absolute/path/to/fixture-releases http://127.0.0.1:8765 /absolute/path/to/Sparkle/bin keybumps-staged
apps/macos/scripts/serve-update-fixture.sh /absolute/path/to/fixture-releases 8765
apps/macos/scripts/verify-update-publication.sh /absolute/path/to/fixture-releases/appcast.xml /absolute/path/to/fixture-releases/Keybumps.zip /absolute/path/to/fixture-releases/Keybumps.md http://127.0.0.1:8765/appcast.xml --verify-live
```

Build N with the staged public key, launch it with `KEYBUMPS_UPDATE_FIXTURE_FEED_URL=http://127.0.0.1:8765/appcast.xml`, and exercise the standard Sparkle flow. Local fixture proof is separate from Developer ID/notarized staged acceptance; only the latter is release evidence.

Automated tests prove loopback-only configuration, served-feed parsing, publication byte equivalence, appcast structure, cryptographic tooling, and deterministic app-shell states. Sparkle's actual replacement of an installed application bundle cannot be faithfully simulated from the unit-test host: the remaining live gate is an installed, Developer ID-signed and notarized N→N+1 run from `/Applications`, including Dictation deferral and tamper rejection.
