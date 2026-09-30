#!/usr/bin/env bash
# Checks a running keybumps.app website: key pages, robots.txt, and the sitemaps respond; the
# trailing-slash and legacy redirects take one 308 hop; search-engine rules match the environment
# (only production may be indexed); and a workers.dev URL redirects to its branded domain.
# Requests carry the smoke-test header so a workers.dev URL serves the site instead of redirecting.
#
# usage: scripts/smoke.sh <base-url> <staging|production>
#   e.g. scripts/smoke.sh http://localhost:8787 staging
set -euo pipefail

base="${1:?usage: smoke.sh <base-url> <staging|production>}"
env="${2:?usage: smoke.sh <base-url> <staging|production>}"
base="${base%/}"
failed=0
smoke=(-H 'x-keybumps-smoke-test: 1')
case "$env" in
  production) canonical=https://keybumps.app ;;
  staging) canonical=https://staging.keybumps.app ;;
  *)
    echo "unknown environment: $env (want staging or production)" >&2
    exit 2
    ;;
esac

pass() { echo "ok   $1"; }
fail() {
  echo "FAIL $1"
  failed=1
}

expect() {
  local path="$1" want="$2" got
  for _ in 1 2 3 4 5; do
    got="$(curl -s "${smoke[@]}" -o /dev/null -w '%{http_code}' "$base$path" || true)"
    [ "$got" = "$want" ] && break
    sleep 3
  done
  if [ "$got" = "$want" ]; then pass "$got $path"; else fail "$got $path (want $want)"; fi
}

expect_redirect() {
  local path="$1" want="$2" got
  got="$(curl -s "${smoke[@]}" -o /dev/null -w '%{http_code} %{redirect_url}' "$base$path" || true)"
  if [ "$got" = "308 $base$want" ]; then
    pass "308 $path -> $want"
  else
    fail "$path gave '$got' (want 308 -> $want)"
  fi
}

# Pages end in a slash and files never do (SERP URL trailing-slash standard).
for path in / /pricing/ /download/ /license/ /thanks/ /about/ /support/ /contact/ /legal/ \
  /legal/privacy/ /legal/terms/ /legal/refunds/ /legal/dmca/ /legal/affiliate-disclosure/ \
  /sitemap/ /robots.txt /sitemap-index.xml /sitemaps/pages.xml; do
  expect "$path" 200
done

# The other form redirects in one hop. Shipped app builds link to /pricing, and Polar checkout
# and receipts may link to /thanks and /license.
for page in /pricing /download /license /thanks /support /legal/dmca; do
  expect_redirect "$page" "$page/"
done
expect_redirect /robots.txt/ /robots.txt
expect_redirect /sitemaps/pages.xml/ /sitemaps/pages.xml

# Legacy URLs go straight to their page.
for legacy in privacy terms refunds; do
  expect_redirect "/$legacy" "/legal/$legacy/"
  expect_redirect "/$legacy/" "/legal/$legacy/"
done
expect_redirect /sitemap.xml /sitemap-index.xml

# Sitemaps list only canonical URLs: child sitemaps are unslashed files, pages end in a slash.
index_locs="$(curl -s "${smoke[@]}" "$base/sitemap-index.xml" | grep -oE '<loc>[^<]+</loc>' || true)"
page_locs="$(curl -s "${smoke[@]}" "$base/sitemaps/pages.xml" | grep -oE '<loc>[^<]+</loc>' || true)"
if [ -n "$index_locs" ] && ! grep -vqE "^<loc>https://keybumps\.app/[^<]*\.xml</loc>$" <<<"$index_locs"; then
  pass 'sitemap index lists unslashed .xml files on keybumps.app'
else
  fail 'sitemap index has a non-canonical URL'
fi
if [ -n "$page_locs" ] && ! grep -vqE "^<loc>https://keybumps\.app/([^<]*/)?</loc>$" <<<"$page_locs"; then
  pass 'pages sitemap lists slashed page URLs on keybumps.app'
else
  fail 'pages sitemap has a non-canonical URL'
fi

robots="$(curl -s "${smoke[@]}" "$base/robots.txt")"
robots_header="$(curl -sI "${smoke[@]}" "$base/" | tr -d '\r' | grep -i '^x-robots-tag:' || true)"

if [ "$env" = production ]; then
  grep -q '^Allow: /$' <<<"$robots" && pass 'robots.txt allows crawling' ||
    fail 'robots.txt does not allow crawling'
  grep -q '^Sitemap: https://keybumps.app/sitemap-index.xml$' <<<"$robots" &&
    pass 'robots.txt lists the sitemap index' || fail 'robots.txt is missing the sitemap index'
  [ -z "$robots_header" ] && pass 'no X-Robots-Tag' || fail "unexpected $robots_header"
else
  grep -q '^Disallow: /$' <<<"$robots" && pass 'robots.txt disallows crawling' ||
    fail 'robots.txt allows crawling'
  grep -qi 'noindex' <<<"$robots_header" && pass 'X-Robots-Tag noindex' ||
    fail 'missing X-Robots-Tag noindex'
fi

# Without the smoke-test header, a workers.dev URL redirects to the branded domain.
if [[ "$base" == *.workers.dev ]]; then
  # Retry: a new deploy can take a few seconds to replace the previous version at the edge.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    got="$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "$base/legal/terms/" || true)"
    [ "$got" = "308 $canonical/legal/terms/" ] && break
    sleep 3
  done
  if [ "$got" = "308 $canonical/legal/terms/" ]; then
    pass "workers.dev redirects to $canonical"
  else
    fail "workers.dev gave '$got' (want 308 -> $canonical/legal/terms/)"
  fi
fi

exit "$failed"
