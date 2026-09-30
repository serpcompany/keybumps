# keybumps.app website guide

`apps/web/` is the keybumps.app website: Next.js 16 (App Router, Turbopack) on Cloudflare Workers through OpenNext, with shadcn (`base-nova`) and Tailwind v4, Biome, and Vitest. It follows the SERP Next.js website SOP as adapted in [#105](https://github.com/serpcompany/keybumps/issues/105). Run every command from `apps/web/`.

SERP standards this site follows:

- [URL trailing slash](https://github.com/serpcompany/serp/blob/main/docs/engineering/standards/url-trailing-slash.md)
- [Environment configuration](https://github.com/serpcompany/serp/blob/main/docs/engineering/standards/environment-configuration.md)
- [Database management and promotion (Drizzle + D1)](https://github.com/serpcompany/serp/blob/main/docs/engineering/standards/database-management-promotion-drizzle-d1.md): not used. The site has no database, so SOP §5 is skipped.

## Run and verify

| Command | What it does |
| --- | --- |
| `pnpm dev` | Next.js dev server. Cloudflare bindings come from `wrangler.jsonc` through `initOpenNextCloudflareForDev()`. |
| `pnpm lint` | Biome lint and format check. `pnpm format` rewrites formatting. |
| `pnpm typecheck` | `next typegen`, then `tsc --noEmit`. |
| `pnpm test` | Vitest, `src/**/*.test.ts`. |
| `pnpm check` | lint, typecheck, test, then an OpenNext build (`opennextjs-cloudflare build`, which runs `next build`). CI runs this on pull requests (`.github/workflows/web.yml`). |
| `pnpm preview` | OpenNext build, then the Worker in local workerd at `http://localhost:8787`. This is the closest local match to production. |
| `scripts/smoke.sh <base-url> <staging\|production>` | Checks a running site: pages, files, and sitemaps return 200; trailing-slash and legacy redirects take one 308; `robots.txt` and `X-Robots-Tag` match the environment; a `workers.dev` URL redirects to its branded domain. |

Before a pull request:

```sh
pnpm install --frozen-lockfile && pnpm check
pnpm preview                                    # in one terminal
scripts/smoke.sh http://localhost:8787 staging  # in another
```

`pnpm preview` without `SITE_ENV` builds the non-production site, so smoke it as `staging`. To check the production rules, set `SITE_ENV` for both the build and the local Worker, then smoke it as `production`:

```sh
# Any placeholder GTM ID works locally; the smoke test checks where GTM loads.
SITE_ENV=production NEXT_PUBLIC_GTM_ID=GTM-TEST123 pnpm preview --var SITE_ENV:production
scripts/smoke.sh http://localhost:8787 production
```

Without `--var`, the build is production but the Worker isn't: `next.config.ts` drops the `X-Robots-Tag` header, while `robots.txt` and the layout, which render on the Worker at request time, still behave as non-production.

Host redirects (`www`, `workers.dev`) can't be checked through `pnpm preview` today: the top-level custom-domain `routes` in `wrangler.jsonc` make Wrangler replace the request's `Host` header, so host rules never match. `src/lib/redirects.test.ts` covers them instead. To check them in workerd, run `wrangler dev` with a copy of `wrangler.jsonc` that has no `routes` (for example in the ignored `.wrangler/` directory, with its paths adjusted) and send `curl -H 'Host: www.keybumps.app'`. Once #144 moves the routes into the deployed environments, the top level has none.

## Environments

| Environment | URL | `SITE_ENV` | Indexing | Analytics |
| --- | --- | --- | --- | --- |
| Local (`pnpm dev`, `pnpm preview`) | `http://localhost:3000`, `http://localhost:8787` | unset | `noindex` | off |
| Staging | `https://staging.keybumps.app` | `staging` | `noindex` | off |
| Production | `https://keybumps.app` | `production` | allowed | GTM when `NEXT_PUBLIC_GTM_ID` is set |

TODO(#144): the staging and production Workers (`keybumps-web-staging`, `keybumps-web-production`), their `wrangler.jsonc` environments and routes, and their `workers.dev` URLs.

## Deploys

TODO(#144): deploys run only through CI (`.github/workflows/web-deploy.yml`): staging, its smoke test, then production and its smoke test. Until then, production still deploys from `serpcompany/keybumps.app` through Workers Builds, and nothing merged here deploys.

Never run `pnpm deploy:cloudflare`, `pnpm upload:cloudflare`, `wrangler deploy`, or `wrangler versions upload` by hand without fresh owner authorization. #144 replaces the first two with `deploy:staging` and `deploy:production`.

## Rollback

TODO(#144): `wrangler rollback --name keybumps-web-production`, and how to confirm it with the production smoke test.

## Environment configuration

Configuration is explicit per environment and falls back to the safe behavior: a site is non-production (noindex, no analytics) unless `SITE_ENV=production`.

| Setting | Kind | Where it is set | Used by |
| --- | --- | --- | --- |
| `SITE_ENV` | build time **and** runtime | The deploy build command, and the Worker's `vars` (#144) | `isProductionSite()` in `src/lib/site.ts`. `next.config.ts` (the `X-Robots-Tag` header and the `workers.dev` redirect target) reads the build-time value. OpenNext renders `robots.txt` and pages on the Worker at request time, so they, and the analytics in the layout, read the runtime value. Both must match, or production ships a `robots.txt` that disallows crawling. |
| `NEXT_PUBLIC_GTM_ID` | build time | The production deploy build (#144, from the GitHub `production` environment's variables) | `src/components/analytics.tsx` |
| `NEXT_PUBLIC_CF_BEACON_TOKEN` | build time | **Must not be set** until the privacy policy covers Cloudflare Web Analytics. The owner chose Google Tag Manager only; setting this token would turn on the beacon without the policy describing it. | `src/components/analytics.tsx` |
| Secrets | runtime | None today. Use `wrangler secret put --env <env>`, never `wrangler.jsonc` or the repository. | none |
| `.dev.vars`, `.env*` | local only | Uncommitted (`.gitignore`) | local runs |

## Canonical URLs and hosts

- Pages end in a slash (`/pricing/`) and files never do (`/robots.txt`). Write only the canonical form in links, canonical tags, sitemaps, and redirect destinations.
- `next.config.ts` sets `trailingSlash: true` and `skipTrailingSlashRedirect: true`. `src/lib/redirects.ts` takes over the trailing-slash redirect because OpenNext runs the built-in one before custom redirects, which would give legacy URLs two hops (`/privacy` → `/privacy/` → `/legal/privacy/`). Every non-canonical URL on the canonical host now takes exactly one 308.
- Legacy URLs (`/privacy`, `/terms`, `/refunds`) are listed in `src/lib/pages.ts` and redirect straight to `/legal/…/`. `/sitemap.xml` redirects to `/sitemap-index.xml`.
- `/pricing/`, `/thanks/`, `/license/`, and `/download/` keep their paths: shipped app builds link to `/pricing`, and Polar checkout and receipts may link to `/thanks` and `/license`.
- `www.keybumps.app` redirects to `https://keybumps.app` in one hop, already in canonical form. A `workers.dev` host redirects to its environment's branded domain (`keybumps.app` in production, `staging.keybumps.app` otherwise), except for requests with the `x-keybumps-smoke-test` header, which CI uses because bot protection on the zone blocks CI runners. The header is not a secret.
- `src/lib/pages.ts` is the single list of indexable static pages. It feeds `/sitemaps/pages.xml`, the HTML `/sitemap/`, and the canonical metadata (`src/lib/metadata.ts`). `/download/` and `/thanks/` stay `noindex` and out of the sitemaps.

## Analytics and privacy

The site uses Google Tag Manager only. `src/components/analytics.tsx` renders nothing unless `SITE_ENV=production`, then loads GTM when `NEXT_PUBLIC_GTM_ID` is set. The privacy policy (`/legal/privacy/`) describes GTM. It also supports the Cloudflare Web Analytics beacon, but `NEXT_PUBLIC_CF_BEACON_TOKEN` must not be set until the privacy policy covers Cloudflare Web Analytics. Any change to analytics tools or tags updates that page in the same pull request.

Analytics never run on pages whose URLs carry checkout, session, or license data. Polar sends buyers to `/thanks/` with a customer-session token in the query string, and GTM tags read the full page URL, so stripping the query string in the container isn't enough. Structurally:

- The site has **two root layouts** and no shared `src/app/layout.tsx`: `src/app/(analytics)/layout.tsx` renders `<Analytics />`, and `src/app/(no-analytics)/layout.tsx` never does. Both render the same document and chrome through `SiteDocument` (`src/components/site-document.tsx`) and the metadata in `src/lib/metadata.ts`. Next.js always does a full page load when navigation crosses root layouts, so GTM, which stays loaded for the life of a document, never carries into these pages through `next/link` or the Back button.
- `/thanks/` and `/license/` (`noAnalyticsPaths` in `src/lib/pages.ts`) live in `(no-analytics)`. New pages go in `(analytics)` unless their URLs can carry such data, in which case they go in `(no-analytics)` and join `noAnalyticsPaths`.
- As second layers, the `(no-analytics)` layout and the global 404 send `referrer: 'no-referrer'` (so the next page's `document.referrer` can't carry the query), and their `StripQuery` component (`src/components/strip-query.tsx`) removes the query string from the address bar and the history entry once the page renders, keeping the App Router's history state so Back still works. It runs once per document, so those pages must not read their query; see the comment in `strip-query.tsx`.
- `src/lib/analytics-scope.test.ts` fails if `src/app/layout.tsx` exists, if the root layouts aren't exactly these two, if a page sits in the wrong group, if the `(no-analytics)` layout or the global 404 stops rendering `<StripQuery />`, or if any source file in `src/` other than `components/analytics.tsx` and the `(analytics)` layout imports the analytics component or mentions another analytics tool. Imports are resolved to files: `@/components/analytics`, `./analytics`, `../components/analytics`, re-exports, `import()`, and `require()` all count, under any local name. Other tools are matched by `@next/third-parties` imports and by `GoogleTagManager`, `GoogleAnalytics`, `googletagmanager`, `google-analytics`, `gtag(`, or `cloudflareinsights`.
- `scripts/smoke.sh <url> production` asserts that `/` loads GTM and that `/thanks/?customer_session_token=x` and `/license/?…` don't. The `/` check needs `NEXT_PUBLIC_GTM_ID` set in the build. It checks first page loads; the separate root layouts cover client-side navigation. In every mode it also asserts that an unknown path returns the 404 page (status 404, `noindex`, `no-referrer`, no GTM).
- With no shared root layout, unmatched URLs render `src/app/global-not-found.tsx` (`experimental.globalNotFound` in `next.config.ts`). It uses `SiteDocument`, sends no referrer, strips the query, and never renders analytics, because a mistyped URL can still carry a checkout or session query.
- Open Graph: Next.js replaces a layout's `openGraph` when a page sets its own, so `pageMetadata()` spreads `defaultOpenGraph` (site name, type, locale, image) into every page's. `src/app/opengraph-image.jpg` sits above the route groups, so `openGraphImage` names it with the cache key Next.js generates. The 404 still gets the generated one, and `scripts/smoke.sh` fails if any key page's `og:image` differs from it, so update `openGraphImage` whenever the image changes. `src/lib/metadata.test.ts` checks that every page, including `/`, `/download/`, `/thanks/`, and the 404, keeps the shared Open Graph details.

## Styling

`src/app/globals.css` loads Tailwind's theme and utilities layers (without the preflight reset) and the shadcn tokens, mapped to the Keybumps palette. The site's own styles live in `src/app/site.css`, which loads into the `components` layer so Tailwind utilities and shadcn components can override them. The site has one dark theme; `<html class="dark">` turns on the dark variants of shadcn components. Add components with `pnpm dlx shadcn@latest add <component>`.
