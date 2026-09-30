# keybumps.app

The product landing page for `keybumps.app`.

## Public URLs

Pages end in a trailing slash and files never do ([SERP URL trailing-slash standard](docs/agents/web.md#canonical-urls-and-hosts)); the other form redirects with one 308.

- `https://keybumps.app/` — one-page product lander (brand assets copied from `serpcompany/keybumps` `brand/`).
- `https://keybumps.app/pricing/` and `/legal/terms/`, `/legal/privacy/`, `/legal/refunds/` — pricing and legal pages needed for Polar checkout review. The old `/terms`, `/privacy`, and `/refunds` URLs redirect to them. Price, checkout link, and the legal "last updated" date live in `src/lib/site.ts`; `CHECKOUT_URL` is the Polar checkout link behind the buy button (set it to `null` to make it download the current DMG instead).
- `https://keybumps.app/thanks/` — Polar checkout success page (set it as the checkout link's success URL). `https://keybumps.app/license/` — where to find the license key (Polar receipt and customer portal, `CUSTOMER_PORTAL_URL` in `src/lib/site.ts`).
- `https://keybumps.app/download/` — stable download link for old links, READMEs, and emails. It has no page: it answers with a temporary 302 (never cached) to the latest macOS DMG, signed with Developer ID. `/download` reaches it with one 308.
- `/about/`, `/support/`, `/contact/`, `/legal/`, `/legal/dmca/`, `/legal/affiliate-disclosure/`, and `/sitemap/` — SOP pages. `src/lib/pages.ts` lists every indexable page for the sitemaps (`/sitemap-index.xml`, `/sitemaps/pages.xml`) and the HTML sitemap.
- `https://updates.keybumps.app/` — release-file origin only. Its root intentionally has no directory page.

Every Download button links straight to the DMG named by `https://updates.keybumps.app/latest.json`, and `/download/` redirects to it; both read the file on request (see [Canonical URLs and hosts](docs/agents/web.md#canonical-urls-and-hosts)). The Keybumps release tooling writes that file (`scripts/write-latest-release-pointer.sh` in `serpcompany/keybumps`) and publishes it beside `appcast.xml`, so a new release needs no change here. The site only accepts a pointer whose DMG is HTTPS on `updates.keybumps.app` and matches the stated version; otherwise, or if the file is unavailable or takes longer than two seconds (`LATEST_RELEASE_TIMEOUT_MS`), it uses `FALLBACK_RELEASE` in `src/lib/latest-release.ts` (currently `0.0.3-beta.8` build `4013`). Keep the fallback on a recent release with in-app licensing, since a buyer who gets it installs that build.

Sparkle appcasts and immutable release assets are owned by the Mac app's release tooling at the repo root and published to `updates.keybumps.app`; do not copy them into `apps/web/`.

## Commands

```sh
pnpm install
pnpm dev
pnpm test
pnpm check
pnpm preview
scripts/smoke.sh http://localhost:8787 staging
```

See [`docs/agents/web.md`](docs/agents/web.md) for what each command verifies and how environments are configured.

The site deploys to Cloudflare Workers through OpenNext. App releases and signed Sparkle update files are owned by `serpcompany/keybumps` and served separately from the R2-backed `updates.keybumps.app` origin.

Deploys run only through CI: each push to `main` that touches `apps/web/` deploys `staging.keybumps.app` (Worker `keybumps-web-staging`), smoke-tests it, then deploys and smoke-tests production (Worker `keybumps-web-production`). See [Deploys](docs/agents/web.md#deploys).

`keybumps.app` and `www.keybumps.app` are served by `keybumps-web-production` since the [domain cutover](docs/agents/web.md#domain-cutover) on 2026-09-30 (serpcompany/keybumps#144). The old repository, `serpcompany/keybumps.app`, is archived, and its Worker is deleted.
