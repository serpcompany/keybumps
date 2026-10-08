#!/usr/bin/env bash
# Deploy only the newest website (SERP ci-workflows standard: deploy only the branch tip). Writes
# deploy=false to $GITHUB_OUTPUT, with a notice, when main has website changes newer than this
# run's commit: each of those pushes starts its own web-deploy run, which deploys them, so a re-run
# of an older run never deploys over newer code. Writes deploy=true when main is this commit, or
# moved on only with changes outside the website (a Mac merge or a release), which start no deploy
# and leave the site this commit built. Fails the step, so nothing deploys, when main can't be
# read, this commit isn't on main, or main is too far ahead to list its changes.
set -euo pipefail

# What a web-deploy run builds from; keep in step with web-deploy.yml's paths.
site='^(apps/web/|docs/releases/|\.github/workflows/web-deploy\.yml$)'

compare="$(gh api "repos/${GITHUB_REPOSITORY}/compare/${GITHUB_SHA}...main" \
  --jq '.status, (.files | length), (.files[] | .filename, (.previous_filename // empty))')"
status="$(sed -n 1p <<<"$compare")"
count="$(sed -n 2p <<<"$compare")"

case "$status" in
identical)
  deploy=true
  ;;
ahead)
  # The compare API lists at most 300 files.
  if [ "$count" -ge 300 ]; then
    echo "::error::main is too far ahead to tell whether it has newer website changes. Run Web deploy from Actions on main."
    exit 1
  fi
  # Not `tail | grep -q`: with pipefail, grep stopping at its first match can kill tail with
  # SIGPIPE and fail the pipeline, which would read as "no website changes".
  if grep -qE "$site" < <(tail -n +3 <<<"$compare"); then
    echo "::notice::main has website changes newer than ${GITHUB_SHA:0:7}; the run for them deploys instead."
    deploy=false
  else
    deploy=true
  fi
  ;;
*)
  echo "::error::${GITHUB_SHA:0:7} isn't on main (compare status: $status)."
  exit 1
  ;;
esac
echo "deploy=$deploy" >>"$GITHUB_OUTPUT"
