# Agent instructions: keybumps.app website

`apps/web/` is the public keybumps.app site: Next.js 16 on Cloudflare Workers through OpenNext, with pnpm 10 and Node 22 (`.nvmrc`). Run site commands from this directory. The Mac app lives at the repo root, and website work never changes it. The root [`AGENTS.md`](../../AGENTS.md) says which of its rules are Mac-only; the rest, including owner authorization, apply here too.

- Follow the SERP Next.js website SOP as adapted for Keybumps in [serpcompany/keybumps#105](https://github.com/serpcompany/keybumps/issues/105). The website agent guide lives at `docs/agents/web.md` in this directory, not in the root `docs/`.
- Website PRs change only `apps/web/**`. Release-please skips a commit only if every file it touches is under `apps/web/`; a commit that also touches a root file counts as an app change and can bump the app version and reach `CHANGELOG.md`. If a root file must change, do it in a separate `chore:`, `docs:`, or `ci:` PR.
- Analytics run in production only, never in development, preview, or staging. The privacy page (`src/app/privacy/page.tsx`) must describe what they collect; change it in the same PR that adds or changes analytics.
- Never log or commit user content: form input, email addresses, license keys, checkout or customer details, or URLs with query strings. Logs hold only structural state, timing, and error category.
- `pnpm install --frozen-lockfile && pnpm check` must pass before a PR. [`.github/workflows/web.yml`](../../.github/workflows/web.yml) runs the same check on pull requests to `main` that touch `apps/web/`; it never deploys.
- Follow the branch, PR, and review cycle in [`docs/development-workflow.md`](../../docs/development-workflow.md). Website work needs no Mac QA candidate (`scripts/build-qa-candidate.sh`). Report build, deterministic tests, `pnpm preview`, deployed and smoke-tested, and owner acceptance separately.
- Shipped app builds link to `https://keybumps.app/pricing` (`Keybumps/Licensing/LicenseModels.swift`), so the pricing page must stay at that path, or at `/pricing/` through one 308.
- Do not deploy, run `wrangler deploy` or `upload`, change Cloudflare, or change the Polar checkout configuration without fresh owner authorization.
