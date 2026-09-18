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

## Release sequence

The normal entry point is `scripts/build-update-release.sh`. It refuses a reused build or existing output directory, archives and exports with Developer ID, submits through the authenticated `asc notarization` API, staples, packages ZIP and DMG artifacts, generates and validates the signed appcast, and creates separate `publication/assets` and `publication/publish-last` directories. It does not upload anything.

1. Increase `CFBundleVersion` above every previously published build and set the customer-facing semantic `MARKETING_VERSION`.
2. Archive arm64 Keybumps with the stable `com.serp.keybumps` bundle ID, the production feed URL, and the matching public key.
3. Export with Developer ID, notarize, staple, and package the stapled app as the Sparkle update archive and DMG.
4. Put the update archive and matching `.md` release notes in a clean staging directory.
5. Run Sparkle's `generate_appcast` through `scripts/generate-staged-appcast.sh`. The private key stays in Keychain.
6. Run `scripts/validate-update-release.sh` with both the feed URL embedded in the candidate app and the appcast URL currently advertising it. These are normally identical; staged promotion may validate a production-configured candidate advertised from the staging channel. The validator uses Sparkle's official tools and the selected Keychain account to verify that the app's public key matches, then cryptographically verifies the signed feed, archive, and linked release notes. It also fails closed on malformed XML, checksum/size drift, identity/version/feed/compatibility, Apple signature, Gatekeeper, notarization-ticket failures, or appcast assets outside the publication directory. The fixture-only trust-skip option is never valid release evidence.
7. Run `scripts/verify-update-publication.sh <appcast> <archive> <notes> <feed-url> --dry-run` to inspect the two-phase order. Upload immutable archive and notes first, publish the signed appcast last, then use `--verify-live` to compare the exact remote bytes with the locally validated artifacts. This repository does not publish the feed automatically.
8. Install build N in `/Applications`, advertise N+1 on the staged feed, and verify check, download, signature validation, restart, exact N+1 version, and retained non-private fixture preferences. Repeat with active Dictation and confirm restart is refused until Dictation is idle.
9. Corrupt a copy of the signed archive without regenerating the appcast and confirm Sparkle rejects it. Never weaken verification for this test.
10. Promote the exact already-validated files from the staging path to the production path, preserving filenames and bytes. Verify the public production archive and notes before accepting the production appcast.

SuperMac and Keybumps have different bundle identifiers. There is no updater bridge: every existing private-beta tester must quit SuperMac and manually install Keybumps. The retired `https://serpcompany.github.io/supermac-macos-app/updates/appcast.xml` feed returned 404 at the identity cutover and must not be recreated as a cross-bundle bridge.

## Local fixture harness

Resolve packages once so Sparkle's `bin/generate_keys` and `bin/generate_appcast` tools are available. Use a dedicated `keybumps-staged` Keychain account; it is not the production key. Build harmless N and N+1 apps with increasing build numbers and the staged public key, package N+1, add matching release notes, and generate the feed:

```sh
scripts/generate-staged-appcast.sh /absolute/path/to/fixture-releases http://127.0.0.1:8765 /absolute/path/to/Sparkle/bin keybumps-staged
scripts/serve-update-fixture.sh /absolute/path/to/fixture-releases 8765
scripts/verify-update-publication.sh /absolute/path/to/fixture-releases/appcast.xml /absolute/path/to/fixture-releases/Keybumps.zip /absolute/path/to/fixture-releases/Keybumps.md http://127.0.0.1:8765/appcast.xml --verify-live
```

Build N with the staged public key, launch it with `KEYBUMPS_UPDATE_FIXTURE_FEED_URL=http://127.0.0.1:8765/appcast.xml`, and exercise the standard Sparkle flow. Local fixture proof is separate from Developer ID/notarized staged acceptance; only the latter is release evidence.

Automated tests prove loopback-only configuration, served-feed parsing, publication byte equivalence, appcast structure, cryptographic tooling, and deterministic app-shell states. Sparkle's actual replacement of an installed application bundle cannot be faithfully simulated from the unit-test host: the remaining live gate is an installed, Developer ID-signed and notarized N→N+1 run from `/Applications`, including Dictation deferral and tamper rejection.
