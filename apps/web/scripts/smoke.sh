#!/usr/bin/env bash
# Checks a running keybumps.app website: key pages, robots.txt, and the sitemaps respond; the
# trailing-slash and legacy redirects take one 308 hop; search-engine rules and analytics match the
# environment (only production may be indexed or load GTM, and never on /thanks/ or /license/);
# and the non-canonical hosts (www and workers.dev) redirect to the branded domain in one 308.
# Requests carry the smoke-test header so a workers.dev URL serves the site instead of redirecting.
#
# Host checks depend on the base URL:
# - a workers.dev URL (CI): the workers.dev redirect. www.keybumps.app can't be checked from here,
#   because it isn't served by this URL and the zone's bot protection blocks CI runners.
# - https://keybumps.app (after the domain cutover, from the owner's machine): the real www host.
# - localhost (`pnpm preview`): both, by sending their Host header. Wrangler keeps that header only
#   when the config it runs has no custom-domain routes, so use the top level, not `--env staging`.
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

# Each body is captured before grep: piping curl into `grep -q` under pipefail can fail when grep
# exits early, which would flip these results.
robots="$(curl -s "${smoke[@]}" "$base/robots.txt")"
robots_header="$(curl -sI "${smoke[@]}" "$base/" | tr -d '\r' | grep -i '^x-robots-tag:' || true)"
home="$(curl -s "${smoke[@]}" "$base/" || true)"
gtm='googletagmanager\.com/gtm\.js'

if [ "$env" = production ]; then
  grep -q '^Allow: /$' <<<"$robots" && pass 'robots.txt allows crawling' ||
    fail 'robots.txt does not allow crawling'
  grep -q '^Sitemap: https://keybumps.app/sitemap-index.xml$' <<<"$robots" &&
    pass 'robots.txt lists the sitemap index' || fail 'robots.txt is missing the sitemap index'
  [ -z "$robots_header" ] && pass 'no X-Robots-Tag' || fail "unexpected $robots_header"
  if [ -n "$home" ] && ! grep -q '<meta name="robots" content="noindex' <<<"$home"; then
    pass 'no robots noindex meta on /'
  else
    fail '/ is empty or has a robots noindex meta'
  fi
  # GTM loads on ordinary pages, and never on pages whose URLs carry checkout, session, or
  # license data. The query values are placeholders. GTM needs NEXT_PUBLIC_GTM_ID in the build
  # and SITE_ENV=production in the Worker's vars, because the layout renders on request.
  grep -q "$gtm" <<<"$home" && pass 'GTM loads on /' ||
    fail 'GTM missing on / (is NEXT_PUBLIC_GTM_ID set in the build and SITE_ENV in the Worker?)'
  for path in '/thanks/?checkout_id=x&customer_session_token=x' '/license/?customer_session_token=x'; do
    page="$(curl -s "${smoke[@]}" "$base$path" || true)"
    if [ -z "$page" ]; then
      fail "empty response for $path"
    elif grep -q "$gtm" <<<"$page"; then
      fail "GTM loads on $path"
    else
      pass "no GTM on $path"
    fi
  done
else
  grep -q '^Disallow: /$' <<<"$robots" && pass 'robots.txt disallows crawling' ||
    fail 'robots.txt allows crawling'
  grep -qi 'noindex' <<<"$robots_header" && pass 'X-Robots-Tag noindex' ||
    fail 'missing X-Robots-Tag noindex'
  if [ -z "$home" ]; then
    fail 'empty response for /'
  elif grep -q "$gtm" <<<"$home"; then
    fail 'GTM loads on / outside production'
  else
    pass 'no GTM on /'
  fi
fi

# Non-canonical hosts redirect to the canonical host in one 308, already in canonical form: a page
# keeps its path, and a legacy URL goes straight to its page.
# usage: expect_host_redirect <label> <canonical-origin> <url> [curl options...]
# Retries, because a new deploy can take a few seconds to replace the previous version at the edge.
expect_host_redirect() {
  local label="$1" origin="$2" url="$3" path want got
  shift 3
  for path in /legal/terms/ /privacy; do
    want="$origin$path"
    [ "$path" = /privacy ] && want="$origin/legal/privacy/"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      got="$(curl -s "$@" -o /dev/null -w '%{http_code} %{redirect_url}' "$url$path" || true)"
      [ "$got" = "308 $want" ] && break
      sleep 3
    done
    if [ "$got" = "308 $want" ]; then
      pass "$label 308 $path -> $want"
    else
      fail "$label $path gave '$got' (want 308 -> $want)"
    fi
  done
}

case "$base" in
  *.workers.dev)
    # Without the smoke-test header, a workers.dev URL redirects to its branded domain.
    expect_host_redirect workers.dev "$canonical" "$base"
    echo "skip www: www.keybumps.app isn't served through $base; check it against https://keybumps.app"
    ;;
  https://keybumps.app)
    expect_host_redirect www https://keybumps.app https://www.keybumps.app
    ;;
  http://localhost:* | http://127.0.0.1:*)
    # Send each host's Host header to the local Worker. www always redirects to the production
    # apex; workers.dev redirects to this build's branded domain unless it has the smoke header.
    expect_host_redirect www https://keybumps.app "$base" -H 'Host: www.keybumps.app'
    workers_dev=(-H 'Host: keybumps-web.example.workers.dev')
    expect_host_redirect workers.dev "$canonical" "$base" "${workers_dev[@]}"
    got="$(curl -s "${smoke[@]}" "${workers_dev[@]}" -o /dev/null -w '%{http_code}' \
      "$base/legal/terms/" || true)"
    if [ "$got" = 200 ]; then
      pass 'workers.dev with the smoke-test header serves the site'
    else
      fail "workers.dev with the smoke-test header gave $got (want 200)"
    fi
    ;;
  *)
    echo "skip host redirects: no www or workers.dev host to check through $base"
    ;;
esac

exit "$failed"
