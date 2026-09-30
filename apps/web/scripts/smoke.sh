#!/usr/bin/env bash
# Checks a running keybumps.app website: key pages, robots.txt, and the sitemaps respond; the
# trailing-slash and legacy redirects take one 308 hop; search-engine rules match the environment
# (only production may be indexed); in production, GTM loads on /, /thanks/, and /license/;
# /thanks/ and /license/ redirect a query away before rendering; and a workers.dev URL redirects to
# its branded domain.
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
index_xml="$(curl -s "${smoke[@]}" "$base/sitemap-index.xml" || true)"
page_xml="$(curl -s "${smoke[@]}" "$base/sitemaps/pages.xml" || true)"
index_locs="$(grep -oE '<loc>[^<]+</loc>' <<<"$index_xml" || true)"
page_locs="$(grep -oE '<loc>[^<]+</loc>' <<<"$page_xml" || true)"
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

# Unmatched URLs render the global 404 (experimental globalNotFound, since the site has two root
# layouts): status 404, noindex, no referrer, and never analytics, even with a checkout query.
missing='/thanks/x/?customer_session_token=x'
missing_status="$(curl -s "${smoke[@]}" -o /dev/null -w '%{http_code}' "$base$missing" || true)"
missing_page="$(curl -s "${smoke[@]}" "$base$missing" || true)"
if [ "$missing_status" = 404 ] && grep -q '<meta name="robots" content="noindex' <<<"$missing_page" &&
  grep -q '<meta name="referrer" content="no-referrer"' <<<"$missing_page" &&
  ! grep -q 'googletagmanager' <<<"$missing_page"; then
  pass "404 page for unknown paths (noindex, no-referrer, no GTM)"
else
  fail "unknown path $missing gave $missing_status or the wrong 404 page"
fi

# /thanks/ and /license/ never render with a query: Polar's checkout and customer-session
# parameters are redirected away before the page renders (src/lib/sensitive-url.ts), so neither
# the page nor analytics ever holds them. The query values are placeholders. The 404, which can't
# redirect, strips its query in <head> (src/components/strip-query.tsx).
for path in /thanks/ /license/; do
  got="$(curl -s "${smoke[@]}" -o /dev/null -w '%{http_code} %{redirect_url}' \
    "$base$path?checkout_id=x&customer_session_token=x" || true)"
  if [ "$got" = "307 $base$path" ]; then
    pass "307 $path?customer_session_token=… -> $path"
  else
    fail "$path?customer_session_token=… gave '$got' (want 307 -> $path)"
  fi
done
grep -q 'window.history.replaceState(window.history.state' <<<"$missing_page" &&
  pass '404 page strips its query in <head>' || fail '404 page is missing the query strip'

# The pages name src/app/opengraph-image.jpg with a hand-copied cache key (src/lib/metadata.ts).
# The 404 gets the key Next.js generates, so the two must match, or the copy went stale.
og_image() { grep -oE '<meta property="og:image" content="[^"]*"' <<<"$1" | head -1 || true; }
home_page="$(curl -s "${smoke[@]}" "$base/" || true)"
home_og="$(og_image "$home_page")"
missing_og="$(og_image "$missing_page")"
if [ -n "$home_og" ] && [ "$home_og" = "$missing_og" ]; then
  pass 'og:image cache key matches the generated one'
else
  fail "og:image cache key is stale: pages have '$home_og', Next.js generates '$missing_og'"
fi
# Every key page keeps that image: Next.js replaces a layout's openGraph when a page sets one.
for path in /pricing/ /download/ /license/ /thanks/ /about/ /legal/privacy/ /sitemap/; do
  page_og="$(og_image "$(curl -s "${smoke[@]}" "$base$path" || true)")"
  if [ -n "$missing_og" ] && [ "$page_og" = "$missing_og" ]; then
    pass "og:image on $path"
  else
    fail "og:image on $path is '$page_og' (want '$missing_og')"
  fi
done

robots="$(curl -s "${smoke[@]}" "$base/robots.txt")"
robots_header="$(curl -sI "${smoke[@]}" "$base/" | tr -d '\r' | grep -i '^x-robots-tag:' || true)"

if [ "$env" = production ]; then
  grep -q '^Allow: /$' <<<"$robots" && pass 'robots.txt allows crawling' ||
    fail 'robots.txt does not allow crawling'
  grep -q '^Sitemap: https://keybumps.app/sitemap-index.xml$' <<<"$robots" &&
    pass 'robots.txt lists the sitemap index' || fail 'robots.txt is missing the sitemap index'
  [ -z "$robots_header" ] && pass 'no X-Robots-Tag' || fail "unexpected $robots_header"
  # GTM loads on ordinary pages and on /thanks/ and /license/, which never render with a query
  # (checked above). Each body is captured before grep, as for robots.txt: piping curl into
  # `grep -q` under pipefail can fail when grep exits early, which would flip these results.
  gtm='googletagmanager\.com/gtm\.js'
  for path in / /thanks/ /license/; do
    page="$(curl -s "${smoke[@]}" "$base$path" || true)"
    grep -q "$gtm" <<<"$page" && pass "GTM loads on $path" ||
      fail "GTM missing on $path (is NEXT_PUBLIC_GTM_ID set in the build?)"
  done
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
