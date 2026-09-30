# Agent instructions: keybumps.app website

`apps/web/` is the public keybumps.app site: Next.js 16 on Cloudflare Workers through OpenNext, with pnpm 10 and Node 22 (`.nvmrc`). Run site commands from this directory. The Mac app lives at the repo root, and website work never changes it. The repo-wide rules in the root [`AGENTS.md`](../../AGENTS.md) apply here too, including never taking over the owner's screen (computer use, browser control, or other screen control) without an explicit handoff; its Mac app rules don't.

- Follow the SERP Next.js website SOP as adapted for Keybumps in [serpcompany/keybumps#105](https://github.com/serpcompany/keybumps/issues/105). [`docs/agents/web.md`](docs/agents/web.md) is the website agent guide: commands, verification, environment configuration, canonical URLs and hosts, and analytics.
- Website PRs change only `apps/web/**`. Release-please skips a commit only if every file it touches is under `apps/web/`; a commit that also touches a root file counts as an app change and can bump the app version and reach `CHANGELOG.md`. If a root file must change, do it in a separate `chore:`, `docs:`, or `ci:` PR.
- Analytics run in production only, never in development, preview, or staging. The site's privacy page must describe what they collect; change it in the same PR that adds or changes analytics.
- Checkout, session, and license data in a URL must never reach analytics. `/thanks/` gets Polar's customer-session token, and `/license/` is the license-help page; both live in the separate `src/app/(sensitive-url)/` root layout. Each of those pages redirects a request that has a query to its bare URL before rendering (`src/lib/sensitive-url.ts`), the layout also strips any query at the top of `<head>` before the router or GTM starts (`src/components/strip-query.tsx`), and it sends no referrer. Only the two root layouts render `<Analytics />`, and there is no shared `src/app/layout.tsx`, so every navigation into these pages from the rest of the site is a full page load. The global 404 never loads analytics. These pages read their query only to redirect it away, and nothing may link to them with one. `src/lib/analytics-scope.test.ts` and `scripts/smoke.sh` enforce it.
- Do not log or commit user content. On the site that also means form input, email addresses, license keys, checkout or customer details, and URLs with query strings. Logs hold only structural state, timing, and error category.
- Site tests are Vitest (`src/**/*.test.ts`) and run through `pnpm test`. They don't use Swift Testing.
- `pnpm install --frozen-lockfile && pnpm check` must pass before a PR. [`.github/workflows/web.yml`](../../.github/workflows/web.yml) runs the same check on pull requests to `main` that touch `apps/web/`; it never deploys.
- Follow the branch, PR, and review cycle in [`docs/development-workflow.md`](../../docs/development-workflow.md). Website work needs no Mac QA candidate (`scripts/build-qa-candidate.sh`). Report build, deterministic tests, `pnpm preview`, deployed and smoke-tested, and owner acceptance separately.
- Every current route (`/`, `/download`, `/license`, `/pricing`, `/privacy`, `/refunds`, `/terms`, `/thanks`) is an external contract and must keep resolving, directly or through at most one 308, per #105. In particular, shipped app builds link to `https://keybumps.app/pricing` (`Keybumps/Licensing/LicenseModels.swift`). `scripts/smoke.sh` checks each one; the redirects live in `src/lib/redirects.ts`.
- Do not deploy, change Cloudflare, or change the Polar checkout configuration without fresh owner authorization. Never run `pnpm deploy:cloudflare` or `pnpm upload:cloudflare`: they deploy to the live production Worker, and #144 removes them. The same goes for `wrangler deploy` and `wrangler upload`.

<!-- BEGIN:nextjs-agent-rules -->

# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` (resolved from this file's directory; in monorepos the `next` package may not be visible from the repo root) before writing any code. Heed deprecation notices.

This block is written and re-added by `next dev` — verify at `node_modules/next/dist/server/lib/generate-agent-files.js`. Removing it from a diff only re-creates the uncommitted change; committing it with your work keeps the tree clean.

<!-- END:nextjs-agent-rules -->
