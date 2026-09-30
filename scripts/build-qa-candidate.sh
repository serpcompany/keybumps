#!/bin/zsh
# The Mac app moved to apps/macos/ (#161, docs/adr/0003-mac-app-in-apps-macos.md). This shim keeps
# the old command working until #161's cleanup removes it; use apps/macos/scripts/build-qa-candidate.sh.
exec "${0:A:h:h}/apps/macos/scripts/build-qa-candidate.sh" "$@"
