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
| `scripts/smoke.sh <base-url> <staging\|production>` | Checks a running site: pages, files, and sitemaps return 200; trailing-slash and legacy redirects take one 308; `/thanks/` and `/license/` redirect a query away; `robots.txt` and `X-Robots-Tag` match the environment; a `workers.dev` URL redirects to its branded domain. |

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

Before the site goes live (#144), `dmca@keybumps.app`, the contact address on `/legal/dmca/` (from the SERP DMCA page template), must forward to `dmca@serp.co` through Cloudflare Email Routing, and delivery must be verified. Until then, don't claim the address works.

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

Checkout, session, and license data in a URL never reach analytics. Polar sends buyers to `/thanks/` with a customer-session token (a bearer credential for the customer portal) and a checkout ID in the query string. GTM and GA read the full page URL, the referrer, and history state, so filtering in the container isn't enough. GTM runs on `/thanks/` and `/license/`, but they never have a query when it does. Structurally:

- `/thanks/` and `/license/` (`sensitiveUrlPaths` in `src/lib/pages.ts`) live in the `src/app/(sensitive-url)/` root layout; every other page lives in `src/app/(analytics)/`. There is no shared `src/app/layout.tsx`. Both layouts render `<Analytics />` and the same document and chrome through `SiteDocument` (`src/components/site-document.tsx`) and the metadata in `src/lib/metadata.ts`. New pages go in `(analytics)` unless their URLs can carry such data, in which case they go in `(sensitive-url)` and join `sensitiveUrlPaths`.
- **Redirect first.** Each `(sensitive-url)` page starts with `await redirectWithoutQuery(path, searchParams)` (`src/lib/sensitive-url.ts`), so a request with any query gets a 307 to the bare URL before the page renders. This matters because the site renders pages on the Worker at request time, and Next.js puts the request's query into the page's RSC payload (canonical URL, rendered search, and the page segment key), which the App Router copies into `history.state`, which GTM's history-change trigger pushes to the `dataLayer`. The redirect replaces the history entry, so Back never returns to the query. These pages read their query only for this; a query-only request to the unslashed form (`/thanks?…`) takes the trailing-slash 308 and then this 307.
- **Strip in `<head>`, second layer.** The `(sensitive-url)` layout and the global 404 pass `<StripQuery />` as `SiteDocument`'s `head`. It is an inline script that replaces the history entry's URL with its path and hash, keeping the entry's state. A parser-inserted inline script runs before the browser parses anything after it, and the App Router hydrates from the RSC payload in `<body>`, and GTM loads from an effect after hydration, so neither can start before it. If the replace ever throws, it stops the page and reloads without the query.
- **Full loads across the boundary.** Next.js always does a full page load when navigation crosses root layouts, so arriving at a `(sensitive-url)` page from any other page starts a new document, and the steps above run before GTM does. Inside the layout, client-side navigation keeps the document, so nothing may link to a `(sensitive-url)` URL with a query. The `(sensitive-url)` layout sends `referrer: 'no-referrer'`, so the next page's `document.referrer` can't carry anything from these URLs, and so does the 404.
- The global 404 (`src/app/global-not-found.tsx`, `experimental.globalNotFound` in `next.config.ts`) uses `SiteDocument`, sends no referrer, strips the query, and never renders analytics, because a mistyped URL can still carry a checkout or session query and can't redirect it.
- `checkout_id` is not sent to analytics: the redirect drops it with the token. If purchase-return analytics ever need a conversion ID, push it explicitly to the `dataLayer` from server-read data after an owner decision and a privacy-page update; never leave it in the URL.
- `src/lib/analytics-scope.test.ts` fails if `src/app/layout.tsx` exists; if the root layouts aren't exactly these two; if a page sits in the wrong group; if a `(sensitive-url)` page doesn't start with `redirectWithoutQuery` for its own path; if the `(sensitive-url)` layout or the 404 stops passing a `<StripQuery />` element (not a comment) as `SiteDocument`'s `head`, or `SiteDocument` stops rendering `head` first in `<head>`; if a source string links to a `(sensitive-url)` URL with a query; or if any source file other than `components/analytics.tsx` and the two root layouts loads analytics. Imports are read with TypeScript's own scanner (`ts.preProcessFile`), so comments, template-literal and magic-comment `import()`, `require()`, re-exports, and side-effect imports all count, under any local name. They are resolved with `ts.resolveModuleName` and the project's `tsconfig.json` (`@/` paths included) and normalized with `realpathSync.native`, so a case variant such as `./Analytics` counts on macOS. The test walks the import graph, so a file that imports a root layout, or any module that reaches `components/analytics.tsx`, counts too. Other tools are matched by `@next/third-parties` imports and by `GoogleTagManager`, `GoogleAnalytics`, `googletagmanager`, `google-analytics`, `gtag(`, or `cloudflareinsights` anywhere in the source.
- `scripts/smoke.sh` asserts in every mode that `/thanks/?…` and `/license/?…` return a 307 to the bare URL, that an unknown path returns the 404 page (status 404, `noindex`, `no-referrer`, no GTM), and that the 404 strips its query. In production mode it asserts that GTM loads on `/`, `/thanks/`, and `/license/` (this needs `NEXT_PUBLIC_GTM_ID` set in the build). It checks first page loads; client-side navigation is covered by the layout split and a headless-browser check (see #151).
- Open Graph: Next.js replaces a layout's `openGraph` when a page sets its own, so `pageMetadata()` spreads `defaultOpenGraph` (site name, type, locale, image) into every page's. `src/app/opengraph-image.jpg` sits above the route groups, so `openGraphImage` names it with the cache key Next.js generates. The 404 still gets the generated one, and `scripts/smoke.sh` fails if any key page's `og:image` differs from it, so update `openGraphImage` whenever the image changes. `src/lib/metadata.test.ts` checks that every page, including `/`, `/download/`, `/thanks/`, and the 404, keeps the shared Open Graph details.

## Styling

`src/app/globals.css` loads Tailwind's theme and utilities layers (without the preflight reset) and the shadcn tokens, mapped to the Keybumps palette. The site's own styles live in `src/app/site.css`, which loads into the `components` layer so Tailwind utilities and shadcn components can override them. The site has one dark theme; `<html class="dark">` turns on the dark variants of shadcn components. Add components with `pnpm dlx shadcn@latest add <component>`.
