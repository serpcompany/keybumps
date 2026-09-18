# Development and manual QA workflow

This is the general Keybumps development cycle for feature work, bug fixes, local builds, and owner acceptance. Public Sparkle distribution is a later, separate operation documented in [`releases/sparkle-update-operations.md`](releases/sparkle-update-operations.md).

## 1. Establish the base

- Treat `main` as the accepted product baseline.
- Confirm completed, owner-accepted work has been promoted to `main` before starting dependent work.
- Create new issue work from current `main`, or bring an existing issue branch up to date with current `main` before continuing.
- Do not infer that a larger local version number means a build contains every earlier experiment. Reverted work is intentionally absent.

## 2. Implement one issue boundary

- Keep the branch tied to its GitHub issue, parent, blockers, and acceptance criteria.
- Separate unrelated feature additions into their own issues.
- Run deterministic tests and a Release build appropriate to the changed behavior.
- Treat build success, rendered UI, signed runtime, installed artifact, and owner acceptance as separate evidence levels.

## 3. Prepare a local manual-QA build

- Build from the exact issue-branch state intended for review.
- Use a development-only label that identifies the issue or branch; do not reuse public release names for local candidates.
- Record the branch and full commit SHA in the QA handoff.
- Keep the stable `com.serp.keybumps` bundle identity and signing identity so permission-sensitive testing remains meaningful.
- Sign installed manual-QA candidates with `Developer ID Application` using the same designated requirement as the accepted baseline. An Apple Development-signed Debug/test host is a different TCC identity and must never be installed as a permission-continuity candidate.
- Keybumps registers its own Launch at Login item only after fresh onboarding.
- Replace the installed app with the intended candidate, launch it from `/Applications`, and verify that the running artifact is the candidate just built.

## 4. Give the owner a scoped hit list

- List only behavior actually present in that candidate.
- Distinguish regression checks from new acceptance checks.
- Explicitly list related work that is not included yet.
- Record pass, failure, skipped, blocked, and follow-up findings in the owning GitHub issue.

## 5. Promote accepted work

- Do not treat a local candidate as the new baseline merely because it was installed.
- After owner acceptance and independent review, merge the accepted issue boundary into `main`.
- Update dependent branches from the new `main` before producing their next candidates.
- Delete superseded local candidates and derived build caches after preserving any required release or issue evidence.

## 6. Publish only when requested

- A local manual-QA build is not a public beta or Sparkle release.
- Tagging, notarized distribution, GitHub Releases, Pages assets, and appcast publication follow the separate release operations document and require explicit owner authorization.
