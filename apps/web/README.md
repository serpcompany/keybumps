# keybumps.app

The product landing page for `keybumps.app`.

## Public URLs

- `https://keybumps.app/` — one-page product lander (brand assets copied from `serpcompany/keybumps` `brand/`).
- `https://keybumps.app/pricing`, `/terms`, `/privacy`, `/refunds` — pricing and legal pages needed for Polar checkout review. Price, checkout link, and the legal "last updated" date live in `src/lib/site.ts`; `CHECKOUT_URL` is the Polar checkout link behind the buy button (set it to `null` to fall back to `/download`).
- `https://keybumps.app/thanks` — Polar checkout success page (set it as the checkout link's success URL). `https://keybumps.app/license` — where to find the license key (Polar receipt and customer portal, `CUSTOMER_PORTAL_URL` in `src/lib/site.ts`).
- `https://keybumps.app/download` — stable user-facing download page with a clickable link to the latest notarized macOS DMG.
- `https://updates.keybumps.app/` — release-file origin only. Its root intentionally has no directory page.

The download page reads `https://updates.keybumps.app/latest.json` (re-checked at most every five minutes) and links to the DMG it names. The Keybumps release tooling writes that file (`scripts/write-latest-release-pointer.sh` in `serpcompany/keybumps`) and publishes it beside `appcast.xml`, so a new release needs no change here. The page only accepts a pointer whose DMG is HTTPS on `updates.keybumps.app` and matches the stated version; otherwise, or if the file is unavailable, it shows `FALLBACK_RELEASE` in `src/lib/latest-release.ts` (currently `0.0.3-beta.3` build `4007`).

Sparkle appcasts and immutable release assets remain owned and published by `serpcompany/keybumps`; do not copy them into this repository.

## Commands

```sh
pnpm install
pnpm dev
pnpm test
pnpm check
pnpm preview
```

The site deploys to Cloudflare Workers through OpenNext. App releases and signed Sparkle update files are owned by `serpcompany/keybumps` and served separately from the R2-backed `updates.keybumps.app` origin.

Cloudflare Workers Builds deploys `main` to production and uploads other branches as preview versions. Routine deployments are triggered by Git pushes rather than local deployment commands.

This site now lives in `serpcompany/keybumps` under `apps/web/`. Until serpcompany/keybumps#144 moves deploys to CI here, production still deploys from `serpcompany/keybumps.app` through Workers Builds, so changes merged here don't deploy yet. Don't edit the site in both places.
