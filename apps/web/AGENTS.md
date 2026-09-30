# Agent instructions: keybumps.app website

`apps/web/` is the public keybumps.app site: Next.js 16 on Cloudflare Workers through OpenNext, with pnpm 10 and Node 22 (`.nvmrc`). Run site commands from this directory. The Mac app lives at the repo root, and website work never changes it. The root [`AGENTS.md`](../../AGENTS.md) product and privacy rules are for the Mac app; the rules below govern the site.

- Follow the SERP Next.js website SOP as adapted for Keybumps in [serpcompany/keybumps#105](https://github.com/serpcompany/keybumps/issues/105).
- Analytics run in production only, never in development, preview, or staging. The privacy page (`src/app/privacy/page.tsx`) must describe what they collect; change it in the same PR that adds or changes analytics.
- Never log or commit user content: form input, email addresses, license keys, checkout or customer details, or URLs with query strings. Logs hold only structural state, timing, and error category.
- `pnpm install --frozen-lockfile && pnpm check` must pass before a PR. [`.github/workflows/web.yml`](../../.github/workflows/web.yml) runs the same check on pull requests that touch `apps/web/`; it never deploys.
- Follow the branch, PR, and review cycle in [`docs/development-workflow.md`](../../docs/development-workflow.md). Website-only work needs no Mac QA candidate (`scripts/build-qa-candidate.sh`). Report build, deterministic tests, `pnpm preview`, deployed and smoke-tested, and owner acceptance separately.
- Release-please excludes `apps/web`, so website commits never bump the app version or reach `CHANGELOG.md`.
- Do not deploy, run `wrangler deploy` or `upload`, or change Cloudflare without fresh owner authorization.
