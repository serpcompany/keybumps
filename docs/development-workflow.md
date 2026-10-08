# Development and manual QA workflow

This is the general Keybumps development cycle for feature work, bug fixes, local builds, and owner acceptance. Public Sparkle distribution is a later, separate operation documented in [`releases/sparkle-update-operations.md`](releases/sparkle-update-operations.md).

## Local QA loop at a glance

1. Implement one issue on its branch; commit a clean tree.
2. Agent first pass without taking over the owner's screen (section 3a).
3. `apps/macos/scripts/build-qa-candidate.sh <issue>` builds, backs up, installs, and launches the candidate.
4. Agent posts the scoped hit list and evidence table to the issue (section 4).
5. Owner tests the installed candidate and replies **accept**, **fail** (with findings), or runs `apps/macos/scripts/restore-previous-keybumps.sh` to roll back.
6. Failures are fixed on the same branch and rebuilt; the script increments the candidate build (`.n+1`). Acceptance leads to promotion (section 5).

## 1. Establish the base

- Treat `main` as the accepted product baseline.
- Confirm completed, owner-accepted work has been promoted to `main` before starting dependent work.
- Create new issue work from current `main`, or bring an existing issue branch up to date with current `main` before continuing.
- Do not infer that a larger local version number means a build contains every earlier experiment. Reverted work is intentionally absent.

## 2. Implement one issue boundary

- Keep the branch tied to its GitHub issue, parent, blockers, and acceptance criteria.
- Separate unrelated feature additions into their own issues.
- Run deterministic tests and a Release build appropriate to the changed behavior.

Report evidence at the level actually established:

1. **Build** — compilation and signing succeeded.
2. **Deterministic tests** — domain, state, calculation, and adapter-contract tests passed.
3. **UI tests** — deterministic navigation and visible states passed.
4. **Signed runtime** — macOS integrations were exercised from the stable signed bundle.
5. **Installed artifact** — the exact Developer ID candidate completed the journey from `/Applications`.
6. **Owner acceptance** — the owner performed and accepted the scoped workflow.

A lower level never proves a higher one. In particular, a build does not prove global shortcuts, permissions, window movement, paste, microphone capture, or installed-update replacement.

Tooling, frameworks, and CI placement for each level are decided in [`testing.md`](testing.md). Keep durable test inputs under `apps/macos/KeybumpsTests/Fixtures`. Keep generated builds, result bundles, screenshots, recordings, and logs out of Git. Record concise, privacy-safe evidence and remaining gates in the owning GitHub issue; never commit user content.

## 3. Prepare a local manual-QA build

- Build from the exact issue-branch state intended for review.
- Use a development-only label that identifies the issue or branch; do not reuse public release names for local candidates.
- Record the branch and full commit SHA in the QA handoff.
- Keep the stable `com.serp.keybumps` bundle identity and signing identity so permission-sensitive testing remains meaningful. Only Release and QA candidates carry it; Debug builds (test hosts, `apps/macos/scripts/build-and-run.sh`) are `com.serp.keybumps.debug`: they need their own permission grants if run by hand and never register Launch at Login. A Debug app still uses the same local data folders as the installed app, so `build-and-run.sh` quits both before launching it; unit-test hosts never touch that data.
- Sign installed manual-QA candidates with `Developer ID Application` using the same designated requirement as the accepted baseline. An Apple Development-signed Debug/test host is a different TCC identity and must never be installed as a permission-continuity candidate.
- Keybumps registers its own Launch at Login item only after fresh onboarding.
- Replace the installed app with the intended candidate, launch it from `/Applications`, and verify that the running artifact is the candidate just built.
- `apps/macos/scripts/build-qa-candidate.sh <issue>` performs this step from a clean tree: it archives and Developer ID-exports the current commit as `<release>-dev.issue<N>` with build `<release build>.<issue>.<n>` (ordered above the installed release and below the next public build for Sparkle), refuses if the designated requirement differs from the installed baseline, backs up the installed app under `~/Library/Developer/Keybumps-QA/backups`, installs and launches the candidate, and verifies the running artifact. It never notarizes or publishes. It signs with the Developer ID identity directly, as releases do. After a signing-team change (ADR 0005), pass `--new-signing-team` once to install a candidate whose designated requirement names the new team. Candidates carry the current release's notes, so `open /Applications/Keybumps.app --args -KBPreviewUpdates YES` (with Keybumps quit first) shows the restart prompt and What's New. `-KBTestCrash YES` and `-KBTestFreeze YES` (QA candidates only) crash or freeze it on purpose a few seconds after launch, so a real crash report can be seen arriving in Sentry, or not arriving with the switch off (ADR 0007). `apps/macos/scripts/restore-previous-keybumps.sh` reinstalls the most recent backup.

## 3a. Agent first pass

Before handing a candidate to the owner, the agent verifies what it can without interrupting the owner's work:

- Deterministic tests, extended for the changed behavior.
- Offscreen renders of changed surfaces (for example SwiftUI `ImageRenderer` snapshots) inspected by the agent for layout, truncation, and state.
- The installed candidate launches from `/Applications`, has a valid signature and matching designated requirement, stays running, and loads existing local data. Check persisted data structurally only (counts, kinds, schema) and never read or report user content.

Computer-use or other screen control drives the owner's real mouse, keyboard, and focus. Use it only after the owner explicitly hands over the screen, announce when it starts and ends, and keep it to checks that require real focus (global shortcuts, cross-app paste, permissions, Dictation insertion). Report the first pass as its own evidence; it never substitutes for owner acceptance.

## 4. Give the owner a scoped hit list

- List only behavior actually present in that candidate.
- Distinguish regression checks from new acceptance checks.
- Explicitly list related work that is not included yet.
- Record pass, failure, skipped, blocked, and follow-up findings in the owning GitHub issue.
- Post the hit list on the issue with the candidate version and build, branch, full commit SHA, an evidence table using the levels above, and the rollback command.
- The owner's result is one of: **accept**, **fail** with findings (fix on the branch and produce the next candidate), or **roll back** with `apps/macos/scripts/restore-previous-keybumps.sh` when the candidate blocks everyday use.

## 5. Promote accepted work

- Do not treat a local candidate as the new baseline merely because it was installed.
- `main` requires the `Unit tests (KeybumpsTests)`, `UI tests (with retries)`, and `Website check (pnpm check)` checks (gate jobs that pass when their suite passes or the change touches none of its files; see [`testing.md`](testing.md) › CI), `CodeQL` and its three `Analyze` scans (`CodeQL` alone can read neutral before the scans finish), and a merge queue. Once the checks pass, `gh pr merge --squash` (or Merge when ready on the PR page) adds the PR to the queue, which runs them again on the PR on top of `main` and any PRs ahead of it, then squash-merges it, so nobody needs Update branch. Admins can bypass this, and the account agents use is one, so agents never do (`--admin` or the bypass box). Release PRs get none of the three gate checks, because release-please opens them (only CodeQL runs), so they can't pass the queue, and the owner merges them with the admin bypass; the release workflow runs both suites before it builds.
- After owner acceptance and independent review, merge the accepted issue boundary into `main`. Website PRs on the root `AGENTS.md`'s listed paths are the exception: an agent merges them after green CI and a clean review.
- Update dependent branches from the new `main` before producing their next candidates.
- While a candidate awaits acceptance, dependent work may continue on a branch stacked on it; rebase it onto `main` after the parent is promoted, and carry any fixes forward before building its candidate.
- Delete superseded local candidates and derived build caches after preserving any required release or issue evidence.

## 6. Publish only when requested

- A local manual-QA build is not a public beta or Sparkle release.
- Before merging a release PR, merge `docs/releases/v<version>.md` (the What's New notes people see) to `main` in its own `docs:` PR. Release-please rewrites its own branch, so a file committed there can be lost. Without it, the release generates notes from the changelog.
- Releases are cut by merging the release-please `release: Keybumps <version>` PR, which tags, builds, notarizes, and publishes to staging; production waits for owner approval on the `production` environment. See the release operations document. Never tag or publish by hand without explicit owner authorization.
