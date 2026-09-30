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
| `pnpm test:leak` | Builds a production-mode site, serves it on port 8793 (`--port`, or `--base <url>` for a running production-mode preview), and drives headless Chrome through every navigation that could expose `/thanks/` or `/license/` query data to GTM (`scripts/leak-test.mjs`). Needs Google Chrome or `CHROME_PATH`. Required on every Next.js or OpenNext upgrade; see "Analytics and privacy". Not in CI. |
| `scripts/smoke.sh <base-url> <staging\|production>` | Checks a running site: pages, files, and sitemaps return 200; trailing-slash and legacy redirects take one 308; `/thanks/` and `/license/` redirect a query away with a 307, and their RSC requests 404; `robots.txt`, `X-Robots-Tag`, and GTM match the environment; `www` and `workers.dev` redirect to the canonical host in one 308 (which hosts it can check depends on the base URL; see the script's header). |

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

Deploys run only through CI, in `.github/workflows/web-deploy.yml`. It runs on every push to `main` that touches `apps/web/**` or the workflow itself, and on a manual run from Actions on `main`. Runs share the concurrency group `web-deploy` with `cancel-in-progress: false`: a running deploy is never cancelled, and at most one more run waits behind it. A newer waiting run replaces an older one, which is harmless because it deploys the newer `main`, which includes the older commits.

1. **Check:** `pnpm install --frozen-lockfile && pnpm check`.
2. **Staging** (GitHub environment `website-staging`): `pnpm deploy:staging | tee deploy.log` builds with `SITE_ENV=staging` (and, from the workflow, a placeholder `NEXT_PUBLIC_GTM_ID=GTM-STAGING0`) and deploys `--env staging`. Then `scripts/smoke.sh <keybumps-web-staging workers.dev URL from deploy.log> staging` must pass: `noindex`, `robots.txt` disallows crawling, no GTM even though the build has an ID (so the `SITE_ENV` gate is what keeps analytics off), and `workers.dev` redirects to `staging.keybumps.app`.
3. **Production** (`needs: staging`, GitHub environment `website-production`): `pnpm deploy:production` builds with `SITE_ENV=production` and `NEXT_PUBLIC_GTM_ID` from the environment's variables (the job fails first if it's empty), and deploys `--env production`, whose `vars` set `SITE_ENV=production` at runtime. Then `scripts/smoke.sh <keybumps-web-production workers.dev URL> production` must pass: `robots.txt` allows crawling, no `X-Robots-Tag` or `noindex` meta, GTM loads on `/`, `/thanks/`, and `/license/` (whose query is redirected away before they render, which the smoke test checks in every mode), and `workers.dev` redirects to `keybumps.app`.

The owner's approval of a pull request into `main` is what authorizes its production deploy. A failing staging job stops the run before production. `NEXT_PUBLIC_CF_BEACON_TOKEN` is never passed to a build (see [Environment configuration](#environment-configuration)).

CI authenticates with `CLOUDFLARE_API_TOKEN` (`github-actions-keybumps-web`), a secret on the `website-staging` and `website-production` GitHub environments, and the repository variable `CLOUDFLARE_ACCOUNT_ID` (SERP). Both environments accept deployments only from `main`, so no other branch can read the token. They are separate from the Mac release's `production` environment; don't share settings between the two pipelines. The token has Workers Scripts Write, Account Settings Read, Workers Tail Read, and Workers Observability Write across the account, plus Workers Routes Write on the `keybumps.app` zone. Cloudflare can't scope those to single Workers, so the rule is in this repo instead: use it only for `keybumps-web-staging` and `keybumps-web-production`. If a deploy fails with an authorization error, ask the owner; don't widen the token.

`pnpm deploy:staging` and `pnpm deploy:production` exist for human emergency use only, with fresh owner authorization. Never run them, `wrangler deploy`, `wrangler versions upload`, or `wrangler rollback` by hand otherwise. To check the deploy configuration without deploying, build and then run `wrangler deploy --dry-run --env <env> --outdir <dir>`: a dry run compiles the Worker and prints its bindings, without authenticating or uploading anything.

Before the production domains move over (#144), `dmca@keybumps.app`, the contact address on `/legal/dmca/` (from the SERP DMCA page template), must forward to `dmca@serp.co` through Cloudflare Email Routing, and delivery must be verified. Check `support@keybumps.app` the same way. Until then, don't claim the addresses work.

### Domain cutover

TODO(#144): the owner runs this once, watching each step. Nothing here runs by itself, and an agent must not do it. Record the date and the run links on #144.

**Approach: CI takes the domains over.** The first production deploys leave out the production routes. At cutover, a pull request adds them, and that merge's `Web deploy` run moves `keybumps.app` and `www.keybumps.app` from `keybumps-website` to `keybumps-web-production` in one API call. This works because Wrangler (4.135, `publishCustomDomains` in its deploy step) sends `override_existing_origin: true` and `override_existing_dns_record: true` whenever its output isn't a terminal, as in CI (`| tee`). It moves a Custom Domain that another Worker holds without asking. The same behavior is why the routes stay out until Workers Builds is disconnected: otherwise the old deploy path could take the domains back.

**Expected outage: none planned, but not guaranteed.** `keybumps-website` keeps serving until the production deploy step reassigns the domains. That step runs after staging passes and after the new version is uploaded to `keybumps-web-production`. The hostnames' DNS records and certificates already exist; Cloudflare issued an Advanced Certificate for each hostname when it became a Custom Domain, and deleting or moving a Custom Domain doesn't delete that certificate. So the move changes only which Worker the records point to. Cloudflare doesn't document how long that takes to reach every edge location. Expect seconds to a few minutes in which a request reaches either Worker; both serve the same site. If a new certificate were needed after all, HTTPS on the affected hostname would fail until it is issued, usually within minutes. The slower alternative is to detach the domains in the dashboard first. That leaves the site down until the routes pull request is merged and its whole run (check, staging, production) finishes, so it isn't used.

Before starting:

- `Web deploy` has passed on `main`, including the production smoke test on `workers.dev`, and `https://staging.keybumps.app/robots.txt` disallows crawling.
- The email routing gate above is verified (#143).
- The routes pull request is open, approved, and green (step 2), so merging it is the only step left.

Steps:

1. **Disconnect Workers Builds** from `keybumps-website` (dashboard: Workers & Pages → `keybumps-website` → Settings → Build → Disconnect). The old Worker keeps serving its last deployed version but can no longer redeploy from `serpcompany/keybumps.app` and take the domains back. The site stays up.
2. **Merge the routes pull request.** In `wrangler.jsonc`, it replaces the TODO in `env.production` with the block below, and it updates this guide (the environments table and this section's TODOs):

   ```jsonc
   "routes": [
     { "pattern": "keybumps.app", "custom_domain": true },
     { "pattern": "www.keybumps.app", "custom_domain": true }
   ],
   ```

   The merge's `Web deploy` run deploys staging, then production. The production deploy moves both domains to `keybumps-web-production`, and its log lists them under custom domains. If staging fails, production doesn't run and the domains stay on `keybumps-website`; fix the problem, then re-run. If the production deploy fails with an authorization error on the custom domains, the domains stay where they are. Stop and ask the owner; don't widen the token.
3. **Smoke-test the real domains** from the owner's machine, because bot protection blocks CI runners on them:
   - `scripts/smoke.sh https://keybumps.app production`. Against this URL, the script also checks that `www.keybumps.app` redirects to the apex in one 308. If every request returns 403, bot protection challenged the request; check the pages in a browser instead.
   - `scripts/smoke.sh https://staging.keybumps.app staging`.
   - Check the dashboard: `keybumps.app` and `www.keybumps.app` are listed under `keybumps-web-production` → Settings → Domains & Routes, and not under `keybumps-website`.
   - Send a test message to `dmca@keybumps.app` and `support@keybumps.app` and confirm both still deliver. The deploy was allowed to override DNS records for the two hostnames. That shouldn't touch MX records, but check.
4. **Delete `keybumps-website`** (owner only, in the dashboard, never with the CI token), once the site has run on `keybumps-web-production` long enough to trust it, and after checking the old Worker has no domains or routes left. Until then, it is the cutover's rollback target.
5. **Check that one deploy path remains:** `keybumps-website` is gone, no Worker in the account builds from `serpcompany/keybumps.app`, and `keybumps-web-staging` and `keybumps-web-production` have no Workers Builds connection. Then #145 archives `serpcompany/keybumps.app`.

**Cutover rollback** (only while `keybumps-website` exists). If the problem is the new code rather than the domain move, prefer the [Rollback](#rollback) below: it keeps the domains where they are. To move the domains back, go in this order, because every `Web deploy` run from a `main` that lists the production routes takes the domains again:

1. **Stop CI from taking them back.** Don't skip this step. Reverting the routes alone isn't enough, because merging the revert starts a run, and any run from before the revert still checks out a commit that lists the routes.
   1. Disable the workflow (Actions → `Web deploy` → Disable workflow, or `gh workflow disable web-deploy.yml`), so nothing new starts.
   2. Disabling doesn't stop runs that already exist. List them with `gh run list --workflow web-deploy.yml --limit 20`, and cancel every run that is `in_progress`, `queued`, or `waiting` with `gh run cancel <run-id>`.
   3. Repeat the list until none of those remain. Don't go on to step 3 while one exists: a production `Deploy` step that finishes afterwards takes the domains again.
2. **Revert the routes commit** on `main` through a pull request. While the workflow is disabled, the merge deploys nothing. Removing the routes also doesn't detach anything: Wrangler calls the Custom Domains API only when `routes` lists at least one custom domain, so a deploy without routes leaves existing domains where they are.
3. **Move the domains back:** in the dashboard, remove `keybumps.app` and `www.keybumps.app` from `keybumps-web-production` (Settings → Domains & Routes), then add both to `keybumps-website` as Custom Domains. The site is down between the removal and the add, usually a minute or two. `keybumps-website` serves its last deployed version, because Workers Builds stays disconnected. Don't reconnect it unless it becomes the deploy path again.
4. **Re-enable `Web deploy`** once `main` has no production routes. From then on, new runs update only `keybumps-web-staging` and the production Worker's `workers.dev` URL, and never touch the domains. **Never re-run a `Web deploy` run from before the revert** (Re-run jobs in Actions, or `gh run rerun`): a re-run checks out its original commit, which lists the routes, so it would move the domains back to `keybumps-web-production`. To deploy again, push to `main` or start a new run. Re-run the cutover when the problem is fixed.

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
| `NEXT_PUBLIC_GTM_ID` | build time | The production job of `web-deploy.yml`, from the GitHub `website-production` environment's variables. Staging builds get the placeholder `GTM-STAGING0`, which the `SITE_ENV` gate keeps from rendering; the staging smoke test checks that. | `src/components/analytics.tsx` |
| `NEXT_PUBLIC_CF_BEACON_TOKEN` | build time | **Must not be set** until the privacy policy covers Cloudflare Web Analytics. The owner chose Google Tag Manager only; setting this token would turn on the beacon without the policy describing it. `web-deploy.yml` doesn't pass it. | `src/components/analytics.tsx` |
| Secrets | runtime | None today. Use `wrangler secret put --env <env>`, never `wrangler.jsonc` or the repository. | none |
| `.dev.vars`, `.env*` | local only | Uncommitted (`.gitignore`) | local runs |

### Logs

Workers Logs (`observability` in `wrangler.jsonc`) are on in every environment, with `redact_query_string: true`. Logs and traces record each request's URL, and Polar sends buyers to `/thanks/?checkout_id=…&customer_session_token=…`. Without redaction, every purchase would put a session credential into the account's logs. The block is set at the top level and every environment inherits it. An environment that sets its own `observability` replaces the whole block and must repeat `redact_query_string`. `src/lib/worker-config.test.ts` resolves each environment with Wrangler's own config reader and fails if any of them loses the setting.

The setting covers only Workers Logs and traces. Cloudflare's own zone request logs and analytics for `keybumps.app`, which are outside this repo, can still contain the full URL, including the query string: HTTP traffic analytics, security events, and Logpush, if anyone turns it on. `wrangler tail` output may too; it isn't verified that tail applies the redaction. Treat all of these as holding query strings, and never copy them into issues, pull requests, or logs.

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

Checkout, session, and license data in a URL never reach analytics. Polar sends buyers to `/thanks/` with a customer-session token (a bearer credential for the customer portal) and a checkout ID in the query string. GTM and GA read the full page URL, the referrer, and history state, so filtering in the container isn't enough. GTM runs on `/thanks/` and `/license/`, but they never have a query when it does. Structurally:

- `/thanks/` and `/license/` (`sensitiveUrlPaths` in `src/lib/pages.ts`) live in the `src/app/(sensitive-url)/` root layout; every other page lives in `src/app/(analytics)/`. There is no shared `src/app/layout.tsx`. Both layouts render `<Analytics />` and the same document and chrome through `SiteDocument` (`src/components/site-document.tsx`) and the metadata in `src/lib/metadata.ts`. New pages go in `(analytics)` unless their URLs can carry such data, in which case they go in `(sensitive-url)` and join `sensitiveUrlPaths`.
- **Redirect first.** Each `(sensitive-url)` page starts with `await redirectWithoutQuery(path, searchParams)` (`src/lib/sensitive-url.ts`), so a request with any query gets a 307 to the bare URL before the page renders. This matters because the site renders pages on the Worker at request time, and Next.js puts the request's query into the page's RSC payload (canonical URL, rendered search, and the page segment key), which the App Router copies into `history.state`, which GTM's history-change trigger pushes to the `dataLayer`. The redirect replaces the history entry, so Back never returns to the query. These pages read their query only for this; a query-only request to the unslashed form (`/thanks?…`) takes the trailing-slash 308 and then this 307.
- **Strip in `<head>`, second layer.** The `(sensitive-url)` layout and the global 404 pass `<StripQuery />` as `SiteDocument`'s `head`. It is an inline script that replaces the history entry's URL with its path and hash, keeping the entry's state. It is not first in the rendered `<head>`: React and Next.js hoist the stylesheet, async framework chunks, the `gtm.js` preload, and metadata above it. It still runs in time: as a parser-inserted inline script in `<head>`, it runs before the browser parses `<body>`. The App Router can't start until it has the page's RSC payload, which is inline in `<body>`, and GTM loads from an effect after hydration. If the replace ever throws, it stops the page and reloads without the query.
- **Never rendered client-side.** A page's `redirect()` is only a 307 for a document request; for a client-side navigation it arrives inside a 200 RSC payload after the router has pushed the URL. So `next.config.ts` rewrites every RSC request (header `rsc`, Next's `RSC_HEADER`) for a `(sensitive-url)` page to a path no page serves (`sensitiveUrlRewrites` in `src/lib/sensitive-url-routes.ts`), which gets a 404. Next.js 16.3 turns a non-OK RSC response into a full page load of the URL (`doMpaNavigation` in `fetchServerResponse`), which the page then redirects. It gets there two ways:
  - **Unknown route** (another page, or one the router hasn't learned, such as `/thanks/` → `/license/?…` or `/` → `/thanks/?…`): the router awaits the fetch before committing anything, gets the 404, and does a hard navigation.
  - **Known route, same pathname with a new query** (`/thanks/` → `/thanks/?…`): the router predicts the route and starts a soft navigation first; the dynamic request then 404s and it dispatches a hard navigation. Nothing is pushed only because the soft navigation's transition is still suspended on the missing page data.

  Both are Next.js internals, not documented behavior, so `pnpm test:leak` must pass on every Next.js or OpenNext upgrade; `src/lib/sensitive-url-routes.test.ts` also checks the header name and the non-OK fallback in the installed Next.js source. `router.refresh()` on these pages is a clean reload. Separately, Next.js always does a full page load when navigation crosses root layouts. So every arrival at a `(sensitive-url)` page starts a new document, and the steps above run before GTM does.
- **No links with a query, and no prefetch.** The rewrite keeps a query out of the address bar, history, and GTM's history trigger, but it doesn't make a link that carries one safe: GTM's click triggers push the clicked `href` as `gtm.elementUrl`, and tag code in the old document can read the RSC request URL, resource timing, or the Navigation API's `navigate` event. So nothing may link to `/thanks/` or `/license/` with a query (strings, templates, `+` concatenation, and `{ pathname, query }` objects are all checked). Links to them set `prefetch={false}` (`linkPrefetch()` in `src/lib/pages.ts` for computed hrefs): their RSC requests 404 by design, and a prefetch would log a 404 on every page view. The RSC 404s that do appear (a click on such a link, or a `router` call) are expected; don't "fix" them.
- **Nothing that streams above the redirect.** A `loading.tsx` or a `Suspense` boundary above the page makes it stream, and `redirect()` then becomes a 200 with a meta refresh and the query in the RSC payload. Segment config (`dynamic = 'force-static'`, `revalidate`, …) or `generateStaticParams` can serve the page without running it. So the group holds only its layout and two pages, and they and `SiteDocument` have no `Suspense` or segment config; `cacheComponents` and `ppr` stay off. The `(sensitive-url)` layout sends `referrer: 'no-referrer'`, so the next page's `document.referrer` can't carry anything from these URLs, and so does the 404.
- The global 404 (`src/app/global-not-found.tsx`, `experimental.globalNotFound` in `next.config.ts`) uses `SiteDocument`, sends no referrer, strips the query, and never renders analytics, because a mistyped URL can still carry a checkout or session query and can't redirect it.
- `checkout_id` is not sent to analytics: the redirect drops it with the token. If purchase-return analytics ever need a conversion ID, push it explicitly to the `dataLayer` from server-read data after an owner decision and a privacy-page update; never leave it in the URL.
- `src/lib/analytics-scope.test.ts` fails if `src/app/layout.tsx` exists; if the root layouts aren't exactly these two; if a page sits in the wrong group; if a `(sensitive-url)` page doesn't start with `redirectWithoutQuery` for its own path; if the `(sensitive-url)` layout or the 404 stops passing a `<StripQuery />` element (not a comment) as `SiteDocument`'s `head`, or `SiteDocument` stops rendering `head` as the only source content of `<head>`; if `next.config.ts` stops passing `sensitiveUrlRewrites()` as its only `beforeFiles` rewrites (`src/lib/sensitive-url-routes.test.ts` checks which requests they match, and the Next.js internals they rely on); if any source builds a link to a `(sensitive-url)` page with a query, or a `<Link>` to one prefetches; if the `(sensitive-url)` group holds anything but its layout and two pages, or they or `SiteDocument` use `Suspense` or segment config, or `next.config.ts` turns on `cacheComponents` or `ppr`; or if any source file other than `components/analytics.tsx` and the two root layouts loads analytics. Imports are read with TypeScript's own scanner (`ts.preProcessFile`), so comments, template-literal and magic-comment `import()`, `require()`, re-exports, and side-effect imports all count, under any local name. They are resolved with `ts.resolveModuleName` and the project's `tsconfig.json` (`@/` paths included) and normalized with `realpathSync.native`, so a case variant such as `./Analytics` counts on macOS. The test walks the import graph, so a file that imports a root layout, or any module that reaches `components/analytics.tsx`, counts too. Other tools are matched by `@next/third-parties` imports and by `GoogleTagManager`, `GoogleAnalytics`, `googletagmanager`, `google-analytics`, `gtag(`, or `cloudflareinsights` anywhere in the source.
- `scripts/smoke.sh` asserts in every mode that `/thanks/?…` and `/license/?…` return a 307 to the bare URL, that an unknown path returns the 404 page (status 404, `noindex`, `no-referrer`, no GTM), and that the 404 strips its query. In production mode it asserts that GTM loads on `/`, `/thanks/`, and `/license/` (this needs `NEXT_PUBLIC_GTM_ID` set in the build). It also asserts that an RSC request for `/thanks/` or `/license/` gets a 404. It checks first page loads; client-side navigation is covered by `pnpm test:leak`.
- Open Graph: Next.js replaces a layout's `openGraph` when a page sets its own, so `pageMetadata()` spreads `defaultOpenGraph` (site name, type, locale, image) into every page's. `src/app/opengraph-image.jpg` sits above the route groups, so `openGraphImage` names it with the cache key Next.js generates. The 404 still gets the generated one, and `scripts/smoke.sh` fails if any key page's `og:image` differs from it, so update `openGraphImage` whenever the image changes. `src/lib/metadata.test.ts` checks that every page, including `/`, `/download/`, `/thanks/`, and the 404, keeps the shared Open Graph details.

## Styling

`src/app/globals.css` loads Tailwind's theme and utilities layers (without the preflight reset) and the shadcn tokens, mapped to the Keybumps palette. The site's own styles live in `src/app/site.css`, which loads into the `components` layer so Tailwind utilities and shadcn components can override them. The site has one dark theme; `<html class="dark">` turns on the dark variants of shadcn components. Add components with `pnpm dlx shadcn@latest add <component>`.
