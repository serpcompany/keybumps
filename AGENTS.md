# Agent instructions

Use `CONTEXT.md` terminology, preserve the module boundaries documented in `docs/architecture.md`, and follow the decisions recorded in `docs/adr/`.

## Repo-wide

- Never take over the owner's screen (computer use or browser control) without an explicit handoff.
- Do not log or commit searches, filenames, clipboard values, transcripts, recordings, window/document titles, URLs, or coaching content. Logs and fixtures hold only structural state, timing, stage, error category, and recovery.
- Preserve `LICENSE.rectangle`, `LICENSE.shotnix`, and the provenance ledger for donor-derived behavior.
- Do not publish, create a remote, configure commerce, notarize, or distribute without fresh owner authorization.

## Mac app (everything outside `apps/web/`)

- [`docs/development-workflow.md`](docs/development-workflow.md): Follow this branch, local-build, installed-artifact, manual-QA, and promotion cycle for all product work.
  Hand the owner work through `scripts/build-qa-candidate.sh <issue>` after your own first pass.
- [`docs/testing.md`](docs/testing.md): Test frameworks, snapshot fixtures, testability seams, and CI runner decisions. New tests use Swift Testing.
- User content and processing stay local: no accounts, sync, analytics, cloud transcription, or hosted history.
- Non-goals: App Store distribution, Intel or pre-macOS-14.2 support, third-party extensions, AI rewriting, meeting/system-audio capture, web search, workflows, and text expansion.
- Keybumps uses the clean-break `com.serp.keybumps` identity and starts with its
  own settings and local data. It does not import or manage another app's data.
- A build is not proof of OS integration. Report build, deterministic tests, UI, signed runtime, installed artifact, and owner acceptance separately.

## Website (`apps/web/`)

- [`apps/web/AGENTS.md`](apps/web/AGENTS.md): The keybumps.app website. It sets the site's workflow, tests, and evidence; the repo-wide rules above also apply.
