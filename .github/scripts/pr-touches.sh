#!/usr/bin/env bash
# Whether this pull request, or merge queue group, touches the files a required check covers.
# Required checks must report on every pull request and every merge queue group, so each PR workflow
# runs on all of them and skips its slow job when this writes run=false: a job skipped by its `if:`
# counts as passing. For a group it diffs the group's base commit against its merge commit. Any other
# event (a manual run, or the release gate calling the workflow), and any failure to read the changed
# files, writes run=true.
#
# Usage: pr-touches.sh '<extended regex>'. A file matches if its path, or its old path when renamed,
# matches. It uses the compare API, which needs only `contents: read`, because the release gate
# calls the test workflows with no other permission.
set -uo pipefail

pattern="$1"
run=true
if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ] || [ "${GITHUB_EVENT_NAME:-}" = "merge_group" ]; then
  if diff="$(gh api "repos/${GITHUB_REPOSITORY}/compare/${BASE_SHA}...${HEAD_SHA}" \
    --jq '(.files | length), (.files[] | .filename, (.previous_filename // empty))')"; then
    count="$(head -n 1 <<<"$diff")"
    # The compare API lists at most 300 files; with that many, run the check.
    # Not `tail | grep -q`: with pipefail, grep stopping at its first match can kill tail with
    # SIGPIPE and fail the pipeline, which would read as "no match" and skip the check.
    if [ "$count" -lt 300 ] && ! grep -qE "$pattern" < <(tail -n +2 <<<"$diff"); then
      run=false
    fi
  else
    echo "::warning::Couldn't list the changed files; running the check."
  fi
fi
echo "run=$run" >>"$GITHUB_OUTPUT"
echo "Touches the checked files: $run"
