# GitHub Pages update hosting

SuperMac temporarily uses GitHub Pages as its public, unauthenticated HTTPS origin for Sparkle update metadata and artifacts. The source repository remains private. The Pages workflow uploads only the generated `public/` directory.

## Stable URLs

- Site root: `https://serpcompany.github.io/supermac-macos-app/`
- Production appcast: `https://serpcompany.github.io/supermac-macos-app/updates/appcast.xml`
- Staging appcast: `https://serpcompany.github.io/supermac-macos-app/updates/staging/appcast.xml`
- Production artifacts and release notes: `https://serpcompany.github.io/supermac-macos-app/updates/`
- Staging artifacts and release notes: `https://serpcompany.github.io/supermac-macos-app/updates/staging/`

The appcast URLs intentionally return no feed until a signed release candidate is ready. Placeholder index pages may be public earlier.

## Publication boundary

The GitHub Actions workflow deploys `public/` as one Pages artifact. It does not publish the repository checkout, source code, signing keys, credentials, private test data, or build logs.

Release preparation must stage immutable ZIP/DMG artifacts and signed release notes before placing the signed `appcast.xml` pointer in the same Pages artifact. The production Sparkle private key remains in the operator Keychain and its encrypted recovery backup; it is never placed under `public/`.

The active `devinschumacher` GitHub credential cannot dispatch Actions, so release operators currently trigger this workflow with the configured Actions-enabled `serp-y` organization-admin credential. No credential is stored in the repository or Pages artifact. This operational account constraint may be removed later without changing the public URLs.

## Migration later

The hosting provider may later change to the product download-site domain, Cloudflare R2/Pages, or another static HTTPS origin. A migration must preserve the current feed long enough to publish an app version whose embedded feed URL points at the replacement origin. Existing clients must never be stranded by removing the old appcast first.
