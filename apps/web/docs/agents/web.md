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
| `scripts/smoke.sh <base-url> <staging\|production>` | Checks a running site: pages, files, and sitemaps return 200; trailing-slash and legacy redirects take one 308; `robots.txt`, `X-Robots-Tag`, and GTM match the environment; `www` and `workers.dev` redirect to the canonical host in one 308 (which hosts it can check depends on the base URL; see the script's header). |

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

Without `--var`, the build is production but the Worker isn't: `next.config.ts` drops the `X-Robots-Tag` header, while `robots.txt` and the layout, which render on the Worker at request time, still behave as non-production. The smoke test catches that mismatch.

Against `localhost`, the smoke test also checks the host redirects by sending `Host: www.keybumps.app` and a `workers.dev` `Host`. That works because the top level of `wrangler.jsonc` has no routes. Don't preview with `--env staging` (or `--env production` once it has its routes): Wrangler then replaces the `Host` header with the route's domain, so the host rules never match and those checks fail. `src/lib/redirects.test.ts` covers the same rules.

## Environments

`wrangler.jsonc` has a top level for local runs and one environment per deployed Worker. Bindings, `vars`, `routes`, and `services` aren't inherited, so each environment repeats them, and `WORKER_SELF_REFERENCE` names that environment's own Worker.

| Environment | Worker | Canonical URL | Other hosts (308 to canonical) | `SITE_ENV` (build and `vars`) | Indexing | Analytics |
| --- | --- | --- | --- | --- | --- | --- |
| Local (`pnpm dev`, `pnpm preview`) | none (top level, `keybumps-web`) | `http://localhost:3000`, `http://localhost:8787` | none | unset | `noindex` | off |
| Staging | `keybumps-web-staging` (`--env staging`) | `https://staging.keybumps.app` (custom domain) | its `workers.dev` URL | `staging` | `noindex` | off |
| Production | `keybumps-web-production` (`--env production`) | `https://keybumps.app`, after the [domain cutover](#domain-cutover) | its `workers.dev` URL; `www.keybumps.app` after the cutover | `production` | allowed | GTM (`NEXT_PUBLIC_GTM_ID`) |

Both deployed environments keep `workers_dev: true`, because CI smoke-tests the `workers.dev` URL (the zone's bot protection blocks CI runners on the branded domains). The URL is `https://<worker>.<account subdomain>.workers.dev`, and the deploy log prints it. Without the `x-keybumps-smoke-test` header, it redirects to the environment's canonical URL.

TODO(#144): until the [domain cutover](#domain-cutover), `env.production` has no `routes`. `keybumps.app` and `www.keybumps.app` are still Custom Domains of the old Worker, `keybumps-website`, which deploys from `serpcompany/keybumps.app` through Workers Builds, so production is reachable only at its `workers.dev` URL.

## Deploys

Deploys run only through CI, in `.github/workflows/web-deploy.yml`. It runs on every push to `main` that touches `apps/web/**` or the workflow itself, and on a manual run from Actions on `main`. Runs queue and never cancel each other (concurrency group `web-deploy`).

1. **Check:** `pnpm install --frozen-lockfile && pnpm check`.
2. **Staging:** `pnpm deploy:staging | tee deploy.log` builds with `SITE_ENV=staging` and deploys `--env staging`. Then `scripts/smoke.sh <workers.dev URL from deploy.log> staging` must pass: `noindex`, `robots.txt` disallows crawling, no GTM, and `workers.dev` redirects to `staging.keybumps.app`.
3. **Production** (`needs: staging`, GitHub environment `production`): `pnpm deploy:production` builds with `SITE_ENV=production` and `NEXT_PUBLIC_GTM_ID` from the environment's variables (the job fails first if it's empty), and deploys `--env production`, whose `vars` set `SITE_ENV=production` at runtime. Then `scripts/smoke.sh <workers.dev URL> production` must pass: `robots.txt` allows crawling, no `X-Robots-Tag` or `noindex` meta, GTM loads on `/` but not on `/thanks/` or `/license/`, and `workers.dev` redirects to `keybumps.app`.

The owner's approval of a pull request into `main` is what authorizes its production deploy. A failing staging job stops the run before production. `NEXT_PUBLIC_CF_BEACON_TOKEN` is never passed to a build (see [Environment configuration](#environment-configuration)).

CI authenticates with the repository secret `CLOUDFLARE_API_TOKEN` (`github-actions-keybumps-web`) and the variable `CLOUDFLARE_ACCOUNT_ID` (SERP). The token has Workers Scripts Write, Account Settings Read, Workers Tail Read, and Workers Observability Write across the account, plus Workers Routes Write on the `keybumps.app` zone. Cloudflare can't scope those to single Workers, so the rule is in this repo instead: use it only for `keybumps-web-staging` and `keybumps-web-production`. If a deploy fails with an authorization error, ask the owner; don't widen the token.

`pnpm deploy:staging` and `pnpm deploy:production` exist for human emergency use only, with fresh owner authorization. Never run them, `wrangler deploy`, `wrangler versions upload`, or `wrangler rollback` by hand otherwise. To check the deploy configuration without deploying, build and then run `wrangler deploy --dry-run --env <env> --outdir <dir>`: a dry run compiles the Worker and prints its bindings, without authenticating or uploading anything.

Before the production domains move over (#144), `dmca@keybumps.app`, the contact address on `/legal/dmca/` (from the SERP DMCA page template), must forward to `dmca@serp.co` through Cloudflare Email Routing, and delivery must be verified. Check `support@keybumps.app` the same way. Until then, don't claim the addresses work.

### Domain cutover

TODO(#144): the owner runs this once, watching each step. Nothing here runs automatically, and an agent must not do it. The approach: the first production deploys leave out the production routes, the owner detaches the domains from the old Worker, and a follow-up pull request adds the routes. Record the date and the run links on #144.

Why this order: a Custom Domain belongs to one Worker. When Wrangler runs outside a terminal, as in CI and Workers Builds, it moves a Custom Domain that another Worker holds to the Worker it's deploying, without asking. So adding the routes before the old deploy path is gone could make the two paths take the domains back and forth.

Before starting:

- `Web deploy` has passed on `main`, including the production smoke test on `workers.dev`, and `https://staging.keybumps.app/robots.txt` disallows crawling.
- The email routing gate above is verified (#143).

Steps:

1. **Disconnect Workers Builds** from `keybumps-website` (dashboard: Workers & Pages → `keybumps-website` → Settings → Build → Disconnect), so the old Worker stops redeploying from `serpcompany/keybumps.app`.
2. **Detach the domains** from `keybumps-website` (Settings → Domains & Routes): remove `keybumps.app` and `www.keybumps.app`. The site is down from here until step 3 finishes, which is acceptable because it hasn't launched.
3. **Add the production routes** in a pull request: in `wrangler.jsonc`, replace the TODO in `env.production` with

   ```jsonc
   "routes": [
     { "pattern": "keybumps.app", "custom_domain": true },
     { "pattern": "www.keybumps.app", "custom_domain": true }
   ],
   ```

   and update this guide (the environments table, this section's TODOs). Once the owner merges it, `Web deploy` attaches both domains to `keybumps-web-production`; its log lists them as custom domains. If that step fails with an authorization error, stop and ask the owner: they can attach both domains in the dashboard (`keybumps-web-production` → Settings → Domains & Routes → Add → Custom domain) and re-run the workflow. Don't widen the token.
4. **Smoke-test the real domain** from the owner's machine, because bot protection blocks CI runners on it: `scripts/smoke.sh https://keybumps.app production`. Against this URL, the script also checks that `www.keybumps.app` redirects to the apex in one 308. A new certificate can take a few minutes. If every request returns 403, bot protection challenged the request; check the pages in a browser instead. Also run `scripts/smoke.sh https://staging.keybumps.app staging`.
5. **Delete `keybumps-website`** (owner only, in the dashboard, never with the CI token), after checking it has no domains or routes left. Until then, moving the domains back to it in the dashboard is the cutover's rollback.
6. **Check that one deploy path remains:** `keybumps-website` is gone, no Worker in the account builds from `serpcompany/keybumps.app`, and `keybumps-web-staging` and `keybumps-web-production` have no Workers Builds connection. Then #145 archives `serpcompany/keybumps.app`.

## Rollback

A bad production deploy rolls back to the previous version of the Worker, with fresh owner authorization:

```sh
npx wrangler deployments list --name keybumps-web-production   # find the version to go back to
npx wrangler rollback [version-id] --name keybumps-web-production -m "<reason>"
```

Without a version ID, `wrangler rollback` goes back to the previous version. A version includes its code, `vars`, and bindings; routes and Custom Domains aren't versioned and don't change. Then confirm with the production smoke test against the Worker's `workers.dev` URL from the last deploy log (`scripts/smoke.sh https://keybumps-web-production.<account subdomain>.workers.dev production`), and, after the cutover, against `https://keybumps.app` from the owner's machine. Revert the bad commit on `main` too, or the next deploy ships it again. Staging rolls back the same way with `--name keybumps-web-staging`.

## Environment configuration

Configuration is explicit per environment and falls back to the safe behavior: a site is non-production (noindex, no analytics) unless `SITE_ENV=production`.

| Setting | Kind | Where it is set | Used by |
| --- | --- | --- | --- |
| `SITE_ENV` | build time **and** runtime | The `deploy:staging` and `deploy:production` scripts (build), and each environment's `vars` in `wrangler.jsonc` (runtime) | `isProductionSite()` in `src/lib/site.ts`. `next.config.ts` (the `X-Robots-Tag` header and the `workers.dev` redirect target) reads the build-time value. OpenNext renders `robots.txt` and pages on the Worker at request time, so they, and the analytics in the layout, read the runtime value. Both must match, or production ships a `robots.txt` that disallows crawling. |
| `NEXT_PUBLIC_GTM_ID` | build time | The production job of `web-deploy.yml`, from the GitHub `production` environment's variables. Staging builds never get it. | `src/components/analytics.tsx` |
| `NEXT_PUBLIC_CF_BEACON_TOKEN` | build time | **Must not be set** until the privacy policy covers Cloudflare Web Analytics. The owner chose Google Tag Manager only; setting this token would turn on the beacon without the policy describing it. `web-deploy.yml` doesn't pass it. | `src/components/analytics.tsx` |
| Secrets | runtime | None today. Use `wrangler secret put --env <env>`, never `wrangler.jsonc` or the repository. | none |
| `.dev.vars`, `.env*` | local only | Uncommitted (`.gitignore`) | local runs |

## Canonical URLs and hosts

- Pages end in a slash (`/pricing/`) and files never do (`/robots.txt`). Write only the canonical form in links, canonical tags, sitemaps, and redirect destinations.
- `next.config.ts` sets `trailingSlash: true` and `skipTrailingSlashRedirect: true`. `src/lib/redirects.ts` takes over the trailing-slash redirect because OpenNext runs the built-in one before custom redirects, which would give legacy URLs two hops (`/privacy` → `/privacy/` → `/legal/privacy/`). Every non-canonical URL on the canonical host now takes exactly one 308.
- Legacy URLs (`/privacy`, `/terms`, `/refunds`) are listed in `src/lib/pages.ts` and redirect straight to `/legal/…/`. `/sitemap.xml` redirects to `/sitemap-index.xml`.
- `/pricing/`, `/thanks/`, `/license/`, and `/download/` keep their paths: shipped app builds link to `/pricing`, and Polar checkout and receipts may link to `/thanks` and `/license`.
- `www.keybumps.app` redirects to `https://keybumps.app` in one hop, already in canonical form. A `workers.dev` host redirects to its environment's branded domain (`keybumps.app` in production, `staging.keybumps.app` otherwise), except for requests with the `x-keybumps-smoke-test` header, which CI uses because bot protection on the zone blocks CI runners. The header is not a secret.
- Files from `public/` (`/brand/…`) and the build's static assets (`/_next/static/…`) are served before the Worker runs, so on `www.keybumps.app` and `workers.dev` they return 200 instead of redirecting. That's accepted: they aren't pages, nothing links to them on those hosts, and every page, including `robots.txt` and the sitemaps, still redirects. Routing them through the Worker (`assets.run_worker_first`) would cost a Worker request per asset for no search benefit.
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
