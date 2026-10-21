#!/usr/bin/env bash
# The newest commit in HEAD_SHA's history where a test suite's check run passed, for Release
# Keybumps. It passes that commit to the test workflow as `tested_base`, and pr-touches.sh skips the
# suite when none of its files changed since, as the merge queue does (#615). Every commit on main
# went through the queue, and a queue group's head commit is the commit that lands on main, so the
# queue's check runs are on main's own commits. A commit merged around the queue has none, so the
# walk passes over it and its changes stay in the diff.
#
# Usage: HEAD_SHA=<commit> last-tested.sh '<check run name>'. It lists the newest 50 commits and,
# newest first, each one's check runs of that name, and writes sha=<the first that passed> to
# GITHUB_OUTPUT. The name must match exactly: a release's own runs are named
# `release / unit-tests / …` (`unit-tests / …` when run manually). Only GitHub Actions' runs count,
# so another app with `checks: write` can't report the name. Finding none, or any failed call,
# writes sha= (empty), which runs the suite. It needs `contents: read` and `checks: read`.
set -uo pipefail

name="$1"
found=""
if commits="$(gh api --method GET "repos/${GITHUB_REPOSITORY}/commits" \
  -f sha="$HEAD_SHA" -f per_page=50 --jq '.[].sha')"; then
  for sha in $commits; do
    if ! runs="$(gh api --method GET "repos/${GITHUB_REPOSITORY}/commits/${sha}/check-runs" \
      -f check_name="$name" -f per_page=100 --jq '.check_runs[] | [.name, .app.slug, .conclusion] | @tsv')"; then
      echo "::warning::Couldn't read the check runs of $sha; running the suite."
      break
    fi
    # Compared here as well as filtered by the API, so only this exact name counts. An empty field
    # shifts the ones after it (tabs are IFS whitespace), so it can't read as a pass.
    while IFS=$'\t' read -r run_name app conclusion; do
      if [ "$run_name" = "$name" ] && [ "$app" = github-actions ] && [ "$conclusion" = success ]; then
        found="$sha"
      fi
    done <<<"$runs"
    if [ -n "$found" ]; then
      break
    fi
  done
else
  echo "::warning::Couldn't list the commits; running the suite."
fi
echo "sha=$found" >>"$GITHUB_OUTPUT"
if [ -n "$found" ]; then
  echo "$name last passed on $found."
else
  echo "Found no commit where $name passed; the suite runs."
fi
