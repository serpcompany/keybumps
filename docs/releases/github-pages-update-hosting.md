# GitHub Pages update hosting

SuperMac temporarily uses GitHub Pages as its public, unauthenticated HTTPS origin for Sparkle update metadata and artifacts. The source repository remains private. GitHub Actions is disabled for the owner account, so Pages publishes from a dedicated `gh-pages` branch containing only generated public files.

## Stable URLs

- Site root: `https://serpcompany.github.io/supermac-macos-app/`
- Production appcast: `https://serpcompany.github.io/supermac-macos-app/updates/appcast.xml`
- Staging appcast: `https://serpcompany.github.io/supermac-macos-app/updates/staging/appcast.xml`
- Production artifacts and release notes: `https://serpcompany.github.io/supermac-macos-app/updates/`
- Staging artifacts and release notes: `https://serpcompany.github.io/supermac-macos-app/updates/staging/`

The appcast URLs intentionally return no feed until a signed release candidate is ready. Placeholder index pages may be public earlier.

## Publication boundary

The orphan `gh-pages` branch mirrors the deployable contents of `public/`; it does not contain the repository checkout, source code, signing keys, credentials, private test data, or build logs. GitHub Pages is configured to publish `/` from that branch.

Release preparation must stage immutable ZIP/DMG artifacts and signed release notes before placing the signed `appcast.xml` pointer in the same publication tree. The complete prepared tree is committed and pushed to `gh-pages` only after local validation; assets and notes must exist in the tree before the appcast pointer. The production Sparkle private key remains in the operator Keychain and its encrypted recovery backup; it is never placed under `public/` or on `gh-pages`.

Until GitHub Actions is enabled, publication is an explicit release-operator step. Future automation may replace the branch push while preserving the stable URLs and assets-first/appcast-last contract.

## Migration later

The hosting provider may later change to the product download-site domain, Cloudflare R2/Pages, or another static HTTPS origin. A migration must preserve the current feed long enough to publish an app version whose embedded feed URL points at the replacement origin. Existing clients must never be stranded by removing the old appcast first.
