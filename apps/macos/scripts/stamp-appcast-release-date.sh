#!/bin/zsh
set -euo pipefail

# Adds the release date to a build's appcast item as <keybumps:releaseDate>, the same UTC time the
# app carries as KBBuildReleaseDate, then signs the feed again. The app compares it with the
# license's update year, so a release after the year shows with Renew instead of Install (ADR 0011).
if (( $# < 4 || $# > 5 )); then
  print -u2 "usage: $0 <appcast> <build> <release-date> <sparkle-tools-directory> [keychain-account]"
  exit 64
fi

appcast_path=${1:A}
release_build=$2
release_date=$3
sign_update_tool="${4:A}/sign_update"
keychain_account=${5:-keybumps-staged}
namespace="https://keybumps.app/xml-namespaces/appcast"
# Same signing key as generate-staged-appcast.sh: CI signs from a key file, local runs from the keychain.
typeset -a signing_key
if [[ -n "${KEYBUMPS_SPARKLE_KEY_FILE:-}" ]]; then
  signing_key=(--ed-key-file "$KEYBUMPS_SPARKLE_KEY_FILE")
else
  signing_key=(--account "$keychain_account")
fi

[[ -f "$appcast_path" ]] || { print -u2 "appcast does not exist: $appcast_path"; exit 66; }
[[ -x "$sign_update_tool" ]] || { print -u2 "sign_update not found: $sign_update_tool"; exit 69; }
[[ "$release_build" == <-> ]] || { print -u2 "build must be an integer"; exit 65; }
[[ "$release_date" =~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' ]] || { print -u2 "release date must be a UTC time like 2026-10-19T12:00:00Z"; exit 65; }
! grep -q 'releaseDate>' "$appcast_path" || { print -u2 "appcast already carries a release date"; exit 70; }

# One item per build, so its <sparkle:version> line is unique; the date goes right after it.
version_line="<sparkle:version>$release_build</sparkle:version>"
(( $(grep -c -F "$version_line" "$appcast_path") == 1 )) || { print -u2 "appcast has no single item for build $release_build"; exit 70; }
stamped="$appcast_path.stamped"
KB_LINE="$version_line" KB_DATE="$release_date" KB_NAMESPACE="$namespace" perl -0pe '
  s{(<rss\b)}{$1 xmlns:keybumps="$ENV{KB_NAMESPACE}"} or die "no rss element\n";
  s{(\Q$ENV{KB_LINE}\E)}{$1\n            <keybumps:releaseDate>$ENV{KB_DATE}</keybumps:releaseDate>} or die "no item\n";
' "$appcast_path" > "$stamped"
mv "$stamped" "$appcast_path"
/usr/bin/xmllint --noout "$appcast_path"
"$sign_update_tool" $signing_key "$appcast_path" >/dev/null
grep -q '<!-- sparkle-signatures:' "$appcast_path" || { print -u2 "appcast is not signed after stamping"; exit 70; }
print "Stamped build $release_build's appcast item with release date $release_date and signed the feed again."
