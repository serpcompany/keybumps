# 0005: Keybumps is signed and notarized by team W3GXL2NQQP

Status: Accepted (2026-10-03). Replaces Developer ID team 847HR8U8D9. Tracked by #221.

## Context

Since 0.0.3-beta.4, every release has shipped Developer ID-signed by team 847HR8U8D9 but not notarized, because that team's membership lapsed while it was converting (`KEYBUMPS_NOTARIZE=false`). On 2026-10-03 the owner's other Apple Developer team, W3GXL2NQQP, was approved, and the owner asked to sign and notarize with it.

## Decisions

1. **Signing:** Developer ID signing, notarization, and local builds use team W3GXL2NQQP: `project.yml`, both `ExportOptions-DeveloperID*.plist`, `build-update-release.sh`, and the release check in `validate-update-release.sh`.
2. **Sparkle key unchanged:** the EdDSA update key stays the same. Sparkle 2.10 (`SUUpdateValidator`) accepts an update whose EdDSA signature matches the installed app's key even when the Apple signing team differs, so installed copies update across the change. The EdDSA key and the signing team must never change in the same release.
3. **Notarization on when Apple is ready:** the new certificate and App Store Connect key are in the release secrets (2026-10-03). The first notarization submission was still pending at Apple after 45 minutes, so the owner chose to ship 0.0.3-beta.12 signed but not notarized. `KEYBUMPS_NOTARIZE=false` is removed once a notarization succeeds.
4. **One QA exception:** `build-qa-candidate.sh --new-signing-team` installs one candidate whose designated requirement differs from the installed app's only by the team: the installed one with its team swapped for the export options' team. Every later candidate must match it again.

## Consequences

- **Permissions:** macOS ties privacy permissions to the designated requirement, so the first W3GXL2NQQP build is a new app to it. Accessibility, Input Monitoring, Screen Recording, Microphone, and Speech Recognition must be granted again, and System Settings may list the old entry beside the new one.
- **Keychain:** each item the old build created (the license, sensitive snippets) asks for the login password before the new build can read it, and only Always Allow stops the prompt. Denying it makes the license unreadable. The owner chose (2026-10-03) to keep reading the old items: the release notes tell users to click Always Allow, or to enter their license key again if they denied it.
- **Release notes required:** this PR is a `build:` commit, which release-please leaves out of the changelog. So the first W3GXL2NQQP release, 0.0.3-beta.12, has hand-written notes in `docs/releases/v0.0.3-beta.12.md`, which `write-release-notes.sh` keeps. They tell users what to grant again and what to allow.
- **Old builds:** they keep running with their old signatures, and the 847HR8U8D9 certificate is no longer used.
