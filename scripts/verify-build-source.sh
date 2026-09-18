#!/bin/zsh
set -euo pipefail

if (( $# != 2 )); then
  print -u2 "usage: $0 <public|local> <repository-root>"
  exit 64
fi

build_mode=$1
repository_root=${2:A}
[[ "$build_mode" == public || "$build_mode" == local ]] || {
  print -u2 "build mode must be public or local"
  exit 64
}

actual_root=$(git -C "$repository_root" rev-parse --show-toplevel 2>/dev/null) || {
  print -u2 "build source is not a Git repository: $repository_root"
  exit 65
}
[[ "${actual_root:A}" == "$repository_root" ]] || {
  print -u2 "build source must be the repository root: $repository_root"
  exit 65
}

[[ -z "$(git -C "$repository_root" status --porcelain --untracked-files=normal)" ]] || {
  print -u2 "build source must be clean"
  exit 65
}

source_commit=$(git -C "$repository_root" rev-parse HEAD)
source_branch=$(git -C "$repository_root" symbolic-ref --quiet --short HEAD || print detached)
origin_main=$(git -C "$repository_root" rev-parse --verify refs/remotes/origin/main 2>/dev/null) || {
  print -u2 "build source requires origin/main"
  exit 65
}

if [[ "$build_mode" == public ]]; then
  [[ "$source_branch" == main ]] || {
    print -u2 "public release source must be the main branch, found: $source_branch"
    exit 65
  }
  [[ "$source_commit" == "$origin_main" ]] || {
    print -u2 "public release source must exactly match origin/main"
    exit 65
  }
else
  git -C "$repository_root" merge-base --is-ancestor "$origin_main" "$source_commit" || {
    print -u2 "local candidate source must contain the latest origin/main"
    exit 65
  }
fi

print "source_commit=$source_commit"
print "source_branch=$source_branch"
print "build_kind=$([[ "$build_mode" == public ]] && print public-release || print local-candidate)"
