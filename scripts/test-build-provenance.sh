#!/bin/zsh
set -euo pipefail

repository_root=${0:A:h:h}
guard_script="$repository_root/scripts/verify-build-source.sh"
fixture_root=$(mktemp -d /tmp/supermac-build-source-test.XXXXXX)
trap 'find "$fixture_root" -depth -delete' EXIT

git -C "$fixture_root" init -q -b main
git -C "$fixture_root" config user.email test@example.com
git -C "$fixture_root" config user.name "Build Source Test"
print 'fixture' > "$fixture_root/fixture.txt"
git -C "$fixture_root" add fixture.txt
git -C "$fixture_root" commit -qm 'fixture'
git -C "$fixture_root" update-ref refs/remotes/origin/main HEAD

"$guard_script" public "$fixture_root" >/dev/null

git -C "$fixture_root" switch -qc feature/test
if "$guard_script" public "$fixture_root" >/dev/null 2>&1; then
  print -u2 'feature branch unexpectedly passed public release guard'
  exit 1
fi

git -C "$fixture_root" switch -q main
print 'dirty' >> "$fixture_root/fixture.txt"
if "$guard_script" public "$fixture_root" >/dev/null 2>&1; then
  print -u2 'dirty main unexpectedly passed public release guard'
  exit 1
fi
git -C "$fixture_root" restore fixture.txt

print 'second' > "$fixture_root/second.txt"
git -C "$fixture_root" add second.txt
git -C "$fixture_root" commit -qm 'ahead'
if "$guard_script" public "$fixture_root" >/dev/null 2>&1; then
  print -u2 'main ahead of origin unexpectedly passed public release guard'
  exit 1
fi

git -C "$fixture_root" update-ref refs/remotes/origin/main HEAD
git -C "$fixture_root" switch -q feature/test
if "$guard_script" local "$fixture_root" >/dev/null 2>&1; then
  print -u2 'stale feature branch unexpectedly passed local candidate guard'
  exit 1
fi
git -C "$fixture_root" switch -q main
"$guard_script" local "$fixture_root" >/dev/null

manifest_path="$fixture_root/build-manifest.json"
"$repository_root/scripts/write-build-manifest.sh" \
  "$manifest_path" "0.0.2-dev.fixture" 42 "$(git -C "$fixture_root" rev-parse HEAD)" main local-candidate
[[ "$(/usr/bin/plutil -extract version raw -expect string "$manifest_path")" == "0.0.2-dev.fixture" ]]
[[ "$(/usr/bin/plutil -extract build raw -expect string "$manifest_path")" == 42 ]]
[[ "$(/usr/bin/plutil -extract buildKind raw -expect string "$manifest_path")" == local-candidate ]]
print 'build provenance guard tests passed'
