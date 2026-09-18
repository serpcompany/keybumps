#!/bin/zsh
set -euo pipefail

if (( $# != 6 )); then
  print -u2 "usage: $0 <path> <version> <build> <source-commit> <source-branch> <build-kind>"
  exit 64
fi

manifest_path=${1:A}
/usr/bin/plutil -create xml1 "$manifest_path"
/usr/bin/plutil -insert version -string "$2" "$manifest_path"
/usr/bin/plutil -insert build -string "$3" "$manifest_path"
/usr/bin/plutil -insert sourceCommit -string "$4" "$manifest_path"
/usr/bin/plutil -insert sourceBranch -string "$5" "$manifest_path"
/usr/bin/plutil -insert buildKind -string "$6" "$manifest_path"
/usr/bin/plutil -convert json "$manifest_path"
/usr/bin/plutil -convert json -o /dev/null "$manifest_path"
