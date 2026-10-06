# Agent instructions

Across the repo, including the website, use `CONTEXT.md` terminology, preserve the module boundaries documented in `docs/architecture.md`, and follow the decisions recorded in `docs/adr/`.

## Repo-wide

- Never take over the owner's screen (computer use, browser control, or other screen control) without an explicit handoff.
- Do not log or commit user content: searches, filenames, clipboard values, transcripts, recordings, window/document titles, URLs, or coaching content. Logs and fixtures hold only structural state, timing, stage, error category, and recovery.
- Preserve every `LICENSE.*` and `NOTICES.*` file in `apps/macos/` and the provenance ledger for donor-derived behavior.
- Do not publish, create a remote, configure commerce, notarize, or distribute without fresh owner authorization.

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
