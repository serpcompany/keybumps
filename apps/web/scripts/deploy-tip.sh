#!/usr/bin/env bash
# Deploy only main's tip (SERP ci-workflows standard). Writes deploy=true to $GITHUB_OUTPUT when main
# still points at this run's commit, else deploy=false with a notice, so a re-run of an older run
# never deploys over newer code. If main can't be read, the step fails and nothing deploys.
set -euo pipefail

tip="$(gh api "repos/${GITHUB_REPOSITORY}/commits/main" --jq .sha)"
if [ "$tip" = "$GITHUB_SHA" ]; then
  echo "deploy=true" >>"$GITHUB_OUTPUT"
else
  echo "::notice::main is at ${tip:0:7}, past this run's ${GITHUB_SHA:0:7}; not deploying."
  echo "deploy=false" >>"$GITHUB_OUTPUT"
fi
