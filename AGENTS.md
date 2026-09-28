# Agent instructions

Build the functional MVP in `docs/product/mvp-prd.md`. Use `CONTEXT.md` terminology and preserve the module boundaries documented in `docs/architecture.md`.

- [`docs/development-workflow.md`](docs/development-workflow.md): Follow this branch, local-build, installed-artifact, manual-QA, and promotion cycle for all product work.
  Hand the owner work through `scripts/build-qa-candidate.sh <issue>` after your own first pass; never take over the owner's screen without an explicit handoff.
- [`docs/testing.md`](docs/testing.md): Test frameworks, snapshot fixtures, testability seams, and CI runner decisions. New tests use Swift Testing.

- User content and processing stay local. Do not log searches, filenames, clipboard values, transcripts, or coaching content.
- Keybumps uses the clean-break `com.serp.keybumps` identity and starts with its
  own settings and local data. It does not import or manage another app's data.
- Preserve `LICENSE.rectangle`, `LICENSE.shotnix`, and the provenance ledger for donor-derived behavior.
- A build is not proof of OS integration. Report build, deterministic tests, UI, signed runtime, installed artifact, and owner acceptance separately.
- Do not publish, create a remote, configure commerce, notarize, or distribute without fresh owner authorization.
