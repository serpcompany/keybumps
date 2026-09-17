# Verification status

Report these levels separately: build, deterministic tests, UI, signed runtime, installed artifact, and owner acceptance.

Current evidence is under `docs/evidence/mvp/`. No user content belongs in committed evidence.

The complete user-journey inventory, acceptance steps, and current evidence strength are tracked in [`docs/product/user-journeys.md`](product/user-journeys.md).

The deterministic updater seam, Sparkle integration, local fixture harness, and fail-closed release validation are implemented. A production-signed update remains unaccepted until an owner-controlled HTTPS origin and production Sparkle key are supplied and the installed N→N+1, active-Dictation deferral, tamper rejection, notarization, Gatekeeper, and owner-acceptance checks in [`docs/releases/sparkle-update-operations.md`](releases/sparkle-update-operations.md) are recorded.
