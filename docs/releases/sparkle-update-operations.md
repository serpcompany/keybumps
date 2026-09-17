# Direct update operations

SuperMac uses one Sparkle 2 controller owned by the app shell. Feature modules do not import Sparkle. The standard Sparkle window presents release notes and install choices; SuperMac mirrors structural status in General and its menu. Update requests never contain searches, filenames, Clipboard History, Dictation content, recordings, Key Bumps history, license data, or customer identity.

## Configuration

Release archives must be built with both settings below. They are public configuration, not secrets. The project also enables Sparkle's signed-feed and verify-before-extraction requirements, so `generate_appcast` signs both the archive enclosure and the feed itself.

- `SUPERMAC_UPDATE_FEED_URL=https://<owner-origin>/appcast.xml`
- `SUPERMAC_UPDATE_PUBLIC_KEY=<Sparkle Ed25519 public key>`

An absent or invalid configuration disables the updater truthfully. Debug and tests never use the production feed by default. A Debug fixture can use `SUPERMAC_UPDATE_FIXTURE_FEED_URL=http://127.0.0.1:<port>/appcast.xml`, but its public key must still be injected at build time.

Generate the production key once with Sparkle's `generate_keys --account supermac-production`. Keep the private key only in the operator Keychain/secret store and an encrypted, access-controlled recovery backup. Never commit, print, ship, or upload it. Losing it prevents existing installations from trusting ordinary future updates; key rotation must follow Sparkle's documented migration procedure.

## Release sequence

1. Increase `CFBundleVersion` above every previously published build and set the customer-facing semantic `MARKETING_VERSION`.
2. Archive arm64 SuperMac with the stable `com.serp.supermac` bundle ID, the production feed URL, and the matching public key.
3. Export with Developer ID, notarize, staple, and package the stapled app as the Sparkle update archive and DMG.
4. Put the update archive and matching `.md` release notes in a clean staging directory.
5. Run Sparkle's `generate_appcast` through `scripts/generate-staged-appcast.sh`. The private key stays in Keychain.
6. Run `scripts/validate-update-release.sh`; it fails closed on identity/version/feed/signature/compatibility, Apple signature, Gatekeeper, or notarization-ticket failures.
7. Upload the archive and release notes first. Verify both public unauthenticated HTTPS URLs. Upload `appcast.xml` last so clients never observe a pointer to missing content.
8. Install build N in `/Applications`, advertise N+1 on the staged feed, and verify check, download, signature validation, restart, exact N+1 version, and retained non-private fixture preferences. Repeat with active Dictation and confirm restart is refused until Dictation is idle.
9. Corrupt a copy of the signed archive without regenerating the appcast and confirm Sparkle rejects it. Never weaken verification for this test.
10. Promote the already-validated files to the production origin, again publishing the appcast last.

The published `v0.0.1-beta.1` app has no updater. Every existing tester must manually install the first updater-enabled bridge DMG. Builds after that bridge can use this flow.

## Local fixture harness

Resolve packages once so Sparkle's `bin/generate_keys` and `bin/generate_appcast` tools are available. Use a dedicated `supermac-staged` Keychain account; it is not the production key. Build harmless N and N+1 apps with increasing build numbers and the staged public key, package N+1, add matching release notes, and generate the feed:

```sh
scripts/generate-staged-appcast.sh /absolute/path/to/fixture-releases http://127.0.0.1:8765 /absolute/path/to/Sparkle/bin supermac-staged
scripts/serve-update-fixture.sh /absolute/path/to/fixture-releases 8765
```

Build N with the staged public key, launch it with `SUPERMAC_UPDATE_FIXTURE_FEED_URL=http://127.0.0.1:8765/appcast.xml`, and exercise the standard Sparkle flow. Local fixture proof is separate from Developer ID/notarized staged acceptance; only the latter is release evidence.
