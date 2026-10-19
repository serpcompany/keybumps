#!/bin/zsh
# Reading, writing, and verifying objects in the release origin's R2 bucket, for
# publish-release.sh and publish-release-index.sh. Each caller sets `bucket` and the `wrangler`
# command array before calling these.
#
# Reads go to the R2 bucket itself. Cloudflare Bot Fight Mode blocks CI runners from the public
# updates.keybumps.app host, so public-edge checks use scripts/verify-update-publication.sh from a
# normal network instead.

typeset -gr R2_IMMUTABLE_CACHE="public, max-age=31536000, immutable"
typeset -gr R2_POINTER_CACHE="public, max-age=60, must-revalidate"

content_type() {
  case $1 in
    *.zip) print application/zip ;;
    *.dmg) print application/x-apple-diskimage ;;
    *.md) print "text/markdown; charset=utf-8" ;;
    *.sha256) print "text/plain; charset=utf-8" ;;
    *.xml) print "application/xml; charset=utf-8" ;;
    *.json) print "application/json; charset=utf-8" ;;
    *) print -u2 "unsupported release file: $1"; return 1 ;;
  esac
}

sha() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}' }

# Copies the object into <destination>. Returns 2 when the object does not exist; any other read
# failure prints the error and returns 1, so an unreadable object is never mistaken for a missing
# one and overwritten.
remote_get() {
  local target=$1 destination=$2 errors
  errors=$(/usr/bin/mktemp)
  if $wrangler r2 object get "$bucket/$target" --remote --pipe > "$destination" 2> "$errors"; then
    /bin/rm -f "$errors"
    return 0
  fi
  if /usr/bin/grep -q "The specified key does not exist" "$errors"; then
    /bin/rm -f "$errors"
    return 2
  fi
  print -u2 "could not read $target from R2:"; /bin/cat "$errors" >&2
  /bin/rm -f "$errors"
  return 1
}

# Prints the object's SHA-256, or nothing when it does not exist; any other read failure fails.
remote_sha() {
  local target=$1 temporary result=0
  temporary=$(/usr/bin/mktemp)
  remote_get "$target" "$temporary" || result=$?
  (( result != 0 )) || sha "$temporary"
  /bin/rm -f "$temporary"
  (( result != 1 ))
}

# usage: put <file> <key> <cache-control>
put() {
  local file=$1 key=$2 cache=$3
  $wrangler r2 object put "$bucket/$key" --file "$file" --content-type "$(content_type "$file")" --cache-control "$cache" --remote >/dev/null
}

# Reads the object back from R2 until it matches the local file, for up to about 30 seconds.
verify() {
  local file=$1 key=$2 expected actual
  expected=$(sha "$file")
  for _ in {1..10}; do
    actual=$(remote_sha "$key")
    [[ "$actual" == "$expected" ]] && { print "  verified $key"; return 0; }
    sleep 3
  done
  print -u2 "published $key does not match the local file"; return 1
}
