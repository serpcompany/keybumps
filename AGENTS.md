# Agent instructions

Stage: ship
Agents may merge: listed paths

Set by the owner on 2026-10-08 (#399), under the SERP [verification cadence](https://github.com/serpcompany/serp/blob/main/docs/engineering/standards/verification-cadence.md#merging-and-deploys) standard: the Mac app has public releases and the site takes payments.

- Every PR waits for the owner's approval ("accept" or "merge" in chat counts), except a website PR whose every changed file is on the list below, counting deleted files and both names of a renamed one.
- An agent merges such a PR one at a time, up to date with `main`, once CI is green and the review loop has ended with a round that had no blocking findings. It may arm auto-merge instead, under the SERP standard's "Agent-armed auto-merge" conditions: `main` requires `Unit tests (KeybumpsTests)`, `UI tests (with retries)`, `Website check (pnpm check)`, `CodeQL`, and the three CodeQL scans (`Analyze (actions)`, `Analyze (javascript-typescript)`, `Analyze (python)`), and up-to-date branches.
- Agents merge with `gh pr merge --squash`, never `--admin` or the web page's bypass box: the account they use is an admin, so GitHub would let it skip the checks. Release PRs, which release-please opens without the three gate checks (only CodeQL runs on them), are the owner's to merge with the admin bypass.
- Before its next merge, or before arming the next PR, the agent confirms the latest `web-deploy.yml` run that includes the commit passed staging, production, and their smoke tests. If it failed, fixing it is the next task; a rollback needs the owner.
- A listed-path PR still waits for the owner if it adds a redirect; removes, renames, or moves a page; or changes where a download, buy, license, or legal link points.

Listed paths:

- `apps/web/src/app/(analytics)/page.tsx`, `home-visuals.tsx`, and `palette-demo.tsx`
- `apps/web/src/app/(analytics)/about/**`, `contact/**`, `support/**`, and `plugins/**`
- `apps/web/src/app/site.css`, `favicon.ico`, and `apple-icon.png` (not `legal.css`, `pricing.css`, or `consent.css`, which style the legal and license pages, the pricing card, and the consent banner, or `globals.css`, which loads them)
- `apps/web/src/components/**`, except `analytics.tsx`, `consent-banner.tsx`, `download-link.tsx`, `page-shell.tsx`, `plugin-browser.tsx`, `pricing-card.tsx`, `site-document.tsx`, `site-footer.tsx`, `site-header.tsx`, `site-nav.tsx`, and `strip-query*`
- `apps/web/src/lib/plugins.ts`
- `apps/web/public/brand/**`

Across the repo, including the website, use `CONTEXT.md` terminology, preserve the module boundaries documented in `docs/architecture.md`, and follow the decisions recorded in `docs/adr/`.

## Repo-wide

- Never take over the owner's screen (computer use, browser control, or other screen control) without an explicit handoff.
- Do not log or commit user content: searches, filenames, clipboard values, transcripts, recordings, window/document titles, URLs, or coaching content. Logs and fixtures hold only structural state, timing, stage, error category, and recovery.
- Preserve every `LICENSE.*` and `NOTICES.*` file in `apps/macos/` and the provenance ledger for donor-derived behavior.
- Do not publish, create a remote, configure commerce, notarize, or distribute without fresh owner authorization. The one standing exception is the website deploy that follows an agent's merge under the listed paths above.

## Mac app (`apps/macos/`: its code, tests, scripts, and release tooling)

- [`docs/development-workflow.md`](docs/development-workflow.md): Follow this branch, local-build, installed-artifact, manual-QA, and promotion cycle for all product work.
  Hand the owner work through `apps/macos/scripts/build-qa-candidate.sh <issue>` after your own first pass.
- [`docs/testing.md`](docs/testing.md): Test frameworks, snapshot fixtures, testability seams, and CI runner decisions. New tests use Swift Testing.
- [`docs/adding-a-plugin.md`](docs/adding-a-plugin.md): The checklist for adding a plugin: the app, the tests that list every plugin, the docs, and the website.
- User content and processing stay local: no accounts, sync, analytics, cloud transcription, or hosted history. Crash reports go to Sentry with no user content. A problem report sends what the person writes (paths, URLs, and email addresses removed), an email they add for a reply, and the Mac's details and permission states ([ADR 0007](docs/adr/0007-crash-reports-to-sentry.md)). The owner triages problem reports in Sentry (`report:problem`), as the [SERP problem-report standard](https://github.com/serpcompany/serp/blob/main/docs/engineering/standards/native-app-problem-reports.md) describes.
- Non-goals: App Store distribution, Intel or pre-macOS-14.2 support, third-party extensions, AI rewriting, meeting/system-audio capture, web search, and workflows.
- A build is not proof of OS integration. Report build, deterministic tests, UI, signed runtime, installed artifact, and owner acceptance separately.

## Website (`apps/web/` and website CI such as `.github/workflows/web*.yml`)

- [`apps/web/AGENTS.md`](apps/web/AGENTS.md): The keybumps.app website. It sets the site's workflow, tests, and evidence; the repo-wide rules above also apply. Website CI files at the root follow these Website rules, not the Mac app rules.
- [`docs/adding-a-plugin.md`](docs/adding-a-plugin.md) §4: The website steps for a new plugin, and which go before or after its release.
