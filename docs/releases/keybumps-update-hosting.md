# Historical GitHub Pages update hosting

GitHub Pages contains historical SuperMac artifacts only. Keybumps does not use or republish that signed feed; its clean-break update origin is `updates.keybumps.app`.

## Keybumps URLs

- Production appcast: `https://updates.keybumps.app/appcast.xml`
- Staging appcast: `https://updates.keybumps.app/staging/appcast.xml`

DNS and HTTPS setup are external acceptance gates. Never copy the historical SuperMac appcast or binaries into either Keybumps path.

## Publication boundary

The GitHub Actions workflow validates Keybumps build and release tooling. It does not deploy `public/`, publish a feed, or expose source code, signing keys, credentials, private test data, or build logs.

Release preparation must upload immutable ZIP/DMG artifacts and signed release notes before placing the signed `appcast.xml` pointer at the domain origin. The production Sparkle private key remains in the operator Keychain and its encrypted recovery backup.

The remote repository is `serpcompany/keybumps`. The old SuperMac Pages feed is a historical record and is not a valid Keybumps release destination.
