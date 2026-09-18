# Agent instructions

Build the functional MVP in `docs/product/mvp-prd.md`. Use `CONTEXT.md` terminology and preserve the module boundaries documented in `docs/architecture.md`.

- [`docs/development-workflow.md`](docs/development-workflow.md): Follow this branch, local-build, installed-artifact, manual-QA, and promotion cycle for all product work.

- User content and processing stay local. Do not log searches, filenames, clipboard values, transcripts, or coaching content.
- Keybumps uses the clean-break `com.serp.keybumps` identity. Treat legacy
  SuperMac installs and `com.serp.supermac` data as read-only migration sources;
  never delete or overwrite them automatically.
- Preserve `LICENSE.rectangle` and the provenance ledger for Rectangle-derived behavior.
- A build is not proof of OS integration. Report build, deterministic tests, UI, signed runtime, installed artifact, and owner acceptance separately.
- Do not publish, create a remote, configure commerce, notarize, or distribute without fresh owner authorization.
