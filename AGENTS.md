# Agent instructions

Use `CONTEXT.md` terminology, preserve the module boundaries documented in `docs/architecture.md`, and follow the decisions recorded in `docs/adr/`.

- [`docs/development-workflow.md`](docs/development-workflow.md): Follow this branch, local-build, installed-artifact, manual-QA, and promotion cycle for all product work.
  Hand the owner work through `scripts/build-qa-candidate.sh <issue>` after your own first pass; never take over the owner's screen without an explicit handoff.
- [`docs/testing.md`](docs/testing.md): Test frameworks, snapshot fixtures, testability seams, and CI runner decisions. New tests use Swift Testing.
- [`apps/web/AGENTS.md`](apps/web/AGENTS.md): The keybumps.app website in `apps/web/`. Follow it for website work; the product and privacy rules below are for the Mac app.

- In the Mac app, user content and processing stay local: no accounts, sync, analytics, cloud transcription, or hosted history. Do not log or commit searches, filenames, clipboard values, transcripts, recordings, window/document titles, URLs, or coaching content. Logs and fixtures hold only structural state, timing, stage, error category, and recovery.
- Mac app non-goals: App Store distribution, Intel or pre-macOS-14.2 support, third-party extensions, AI rewriting, meeting/system-audio capture, web search, workflows, and text expansion.
- Keybumps uses the clean-break `com.serp.keybumps` identity and starts with its
  own settings and local data. It does not import or manage another app's data.
- Preserve `LICENSE.rectangle`, `LICENSE.shotnix`, and the provenance ledger for donor-derived behavior.
- A build is not proof of OS integration. Report build, deterministic tests, UI, signed runtime, installed artifact, and owner acceptance separately.
- Do not publish, create a remote, configure commerce, notarize, or distribute without fresh owner authorization.
