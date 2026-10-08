# 0003: The Mac app lives in `apps/macos/`

Status: Accepted (2026-09-30). Reverses "The Mac app stays at the repo root" in `docs/architecture.md` (#146). Tracked by #161.

## Context

#141 moved the website into `apps/web/` and left the Mac app at the repository root on purpose. #161 then inventoried every path the move touches and recommended waiting for a concrete second reason. The owner decided to move it now (2026-09-30), against that recommendation, accepting the risk because the app itself doesn't change: the XcodeGen project regenerates byte-identical, and the Release build settings, bundle ID, team, Info.plist, and entitlements are the same. The result is one layout for both apps, each in its own folder under `apps/`.

## Decisions

1. **What moves.** `apps/macos/` holds the whole Mac app: `Keybumps/`, `KeybumpsTests/`, `KeybumpsUITests/`, the committed `Keybumps.xcodeproj/`, `project.yml`, `scripts/`, and the bundled `LICENSE.*` and `NOTICES.*` files. The licenses move too: `project.yml` bundles them, and leaving them at the root would make XcodeGen add a group named after the checkout directory, so the committed project would differ between clones.
2. **What stays at the root.** `CHANGELOG.md`, `version.txt`, the release-please config and manifest, `docs/` (including `docs/releases/` and this ADR), `AGENTS.md`, `CONTEXT.md`, `README.md`, `brand/`, `public/`, and `.github/`.
3. **Release-please is unchanged.** The package stays `"."` with `exclude-paths: ["apps/web"]`, so app commits under `apps/macos/` still count, and `version.txt`, `CHANGELOG.md`, and the `v<version>` tags keep going as before. Moving the package to `apps/macos` would need tag-continuity testing; do that separately, if ever.
4. **One app-folder setting per workflow.** `release.yml`, `keybumps-unit-tests.yml`, and `keybumps-ui-tests.yml` each set `APP_DIR: apps/macos`. A called workflow doesn't inherit its caller's `env`, so there are three. `release.yml` runs from the repository root and calls `${{ env.APP_DIR }}/scripts/…`; the test workflows run their steps in `APP_DIR` and name it in their cache, `hashFiles`, and upload paths. Their changed-paths patterns (`.github/scripts/pr-touches.sh`, which replaced `paths:` filters in #410) can't use expressions either, so they name `apps/macos/` directly.
5. **Scripts find two roots.** Each script finds the app folder from its own location (`${0:A:h:h}`) and the repository root with `git rev-parse` when it needs a root file. `build-update-release.sh` reads `docs/releases/` that way, so it must run from a Git checkout. `check-legacy-branding.sh` scans the whole repository. The release scripts were made location-independent first, in #162, and a Release Keybumps dry run from that `main` matched beta.8's artifact before this move.
6. **Temporary root shims, now removed.** `scripts/build-qa-candidate.sh` and `scripts/restore-previous-keybumps.sh` at the root `exec`'d the moved scripts so the owner's QA and rollback commands kept working through the move. They were removed after 0.0.3-beta.9 shipped from this layout; use `apps/macos/scripts/build-qa-candidate.sh` and `apps/macos/scripts/restore-previous-keybumps.sh`. The repository root has no `scripts/` folder.

## Consequences

- Commands for the app run from `apps/macos/` or name it: `apps/macos/scripts/build-qa-candidate.sh <issue>`, and `cd apps/macos && xcodegen generate`.
- Git history follows the move: `git log --follow` works for every moved file. A plain diff shows the two shimmed scripts as new files, because their old paths now hold the shims, but `--follow` still finds their history.
- Caches start fresh: the package cache path changes to `apps/macos/.spm`, so the first CI runs after the move resolve packages again. A local `.derived/` at the root is orphaned; `build-and-run.sh` now builds into `apps/macos/.derived/`.
- The installed app's identity and permissions don't change: the designated requirement is the bundle ID and team, with no path.
- Only a real release run proves the whole release path in the new layout. So a Release Keybumps dry run (`publish=false`, `notarize=false`) from the branch, diffed against beta.8's artifact, is required before this merges.
- Proven on 2026-09-30: the dry run from the move branch (run 36696230429) matched beta.8's artifact, and 0.0.3-beta.9 (build 4014, release run 36698736502) was the first published release built from `apps/macos/`.
