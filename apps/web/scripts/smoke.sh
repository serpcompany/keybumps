#!/usr/bin/env bash
# The checks run through `eventually`, which shellcheck cannot follow.
# shellcheck disable=SC2329
# Checks a running keybumps.app website: key pages, robots.txt, and the sitemaps respond; every
# plugin page in the pages sitemap responds, canonical to itself and linked from /plugins/; the
# trailing-slash and legacy redirects take one 308 hop; /download/ sends a 302 to the current DMG,
# which the Download buttons link to directly; search-engine rules and analytics match the
# environment (only production may be indexed or load GTM, which it does on /, /thanks/, and
# /license/); /thanks/ and /license/ redirect a query away before rendering and are never served to
# client-side navigation; and the non-canonical hosts (www and workers.dev) redirect to the branded
# domain in one 308.
# Requests carry the smoke-test header so a workers.dev URL serves the site instead of redirecting.
#
# Every check retries for a short time: right after a deploy, some requests can still reach the
# previous version of the Worker at the edge.
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
# Bounds every request, so a stalled connection counts as one failed try instead of hanging.
limits=(--connect-timeout 5 --max-time 20)
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

# eventually <label> <check> [args...]: passes once <check> succeeds, trying `tries` times (default
# 5), 3 seconds apart. A check sets `why` to describe its last failure. Each check fetches afresh.
# Bodies are captured before grep: piping curl into `grep -q` under pipefail can fail when grep
# exits early, which would flip a result.
eventually() {
  local label="$1" try max="${tries:-5}"
  shift
  for ((try = 1; try <= max; try++)); do
    why=''
    if "$@"; then
      pass "$label"
      return
    fi
    ((try == max)) || sleep 3
  done
  fail "$label: ${why:-check failed}"
}

# fetch <path> [curl options...]: the body, or nothing on a transport error.
fetch() {
  local path="$1"
  shift
  curl -s "${limits[@]}" "${smoke[@]}" "$@" "$base$path" || true
}

# status_is <url> <want> [curl options...]: `<code> <redirect target>` must equal <want>.
status_is() {
  local url="$1" want="$2" got
  shift 2
  got="$(curl -s "${limits[@]}" "$@" -o /dev/null -w '%{http_code} %{redirect_url}' "$url" || true)"
  got="${got% }"
  [ "$got" = "$want" ] || {
    why="got '$got'"
    return 1
  }
}

# body_matches <path> <regex>, body_lacks <path> <regex>: body_lacks needs a non-empty body, so a
# failed request never passes as "absent".
body_matches() {
  grep -qE "$2" <<<"$(fetch "$1")" || {
    why="no match for $2"
    return 1
  }
}
body_lacks() {
  local body
  body="$(fetch "$1")"
  if [ -z "$body" ]; then
    why='empty response'
    return 1
  fi
  if grep -qE "$2" <<<"$body"; then
    why="found $2"
    return 1
  fi
}

# robots_header_is <none|noindex>: the X-Robots-Tag on / of a 200 response.
robots_header_is() {
  local headers tag
  why=''
  headers="$(curl -sI "${limits[@]}" "${smoke[@]}" "$base/" || true)"
  headers="${headers//$'\r'/}"
  if ! grep -qE '^HTTP/[0-9.]+ 200' <<<"$headers"; then
    why='/ did not return 200'
    return 1
  fi
  tag="$(grep -i '^x-robots-tag:' <<<"$headers" || true)"
  case "$1" in
    none) [ -z "$tag" ] || why="unexpected $tag" ;;
    noindex) grep -qi 'noindex' <<<"$tag" || why="got '${tag:-no X-Robots-Tag}'" ;;
  esac
  [ -z "$why" ]
}

# Pages end in a slash and files never do (SERP URL trailing-slash standard).
for path in / /plugins/ /pricing/ /license/ /thanks/ /about/ /support/ /contact/ /legal/ \
  /legal/privacy/ /legal/terms/ /legal/refunds/ /legal/dmca/ /legal/affiliate-disclosure/ \
  /sitemap/ /robots.txt /sitemap-index.xml /sitemaps/pages.xml; do
  eventually "200 $path" status_is "$base$path" 200 "${smoke[@]}"
done

# The other form redirects in one hop. Shipped app builds link to /pricing, builds with
# Settings › Plugins' Browse on keybumps.app button link to /plugins, and Polar checkout and
# receipts may link to /thanks and /license. /download goes to /download/, which then redirects to
# the DMG (checked below).
expect_redirect() {
  eventually "308 $1 -> $2" status_is "$base$1" "308 $base$2" "${smoke[@]}"
}
for page in /pricing /plugins /download /license /thanks /support /legal/dmca; do
  expect_redirect "$page" "$page/"
done

# Every plugin has a page, /plugins/<slug>/, listed in the pages sitemap and linked from /plugins/.
# Each one returns 200 with its own canonical URL, and its unslashed form takes one 308. A slug with
# no plugin is the 404 (dynamicParams = false).
plugin_paths=()
read_plugin_paths() {
  plugin_paths=()
  local path
  while IFS= read -r path; do
    [ -n "$path" ] && plugin_paths+=("$path")
  done < <(grep -oE '<loc>https://keybumps\.app/plugins/[a-z-]+/</loc>' <<<"$(fetch /sitemaps/pages.xml)" |
    sed -E 's#^<loc>https://keybumps\.app(.*)</loc>$#\1#' || true)
  if [ "${#plugin_paths[@]}" -lt 8 ]; then
    why="want 8+ plugin pages in /sitemaps/pages.xml, got ${#plugin_paths[@]}"
    return 1
  fi
}
eventually 'pages sitemap lists every plugin page' read_plugin_paths
# plugin_page_ok <path>: 200, canonical to itself, and linked from /plugins/.
plugins_page=''
plugin_page_ok() {
  local body
  body="$(fetch "$1")"
  if ! grep -qF "<link rel=\"canonical\" href=\"https://keybumps.app$1\"/>" <<<"$body"; then
    why="no canonical link to https://keybumps.app$1"
    return 1
  fi
  [ -n "$plugins_page" ] || plugins_page="$(fetch /plugins/)"
  grep -qF "href=\"$1\"" <<<"$plugins_page" || {
    why="/plugins/ doesn't link to $1"
    return 1
  }
}
for path in "${plugin_paths[@]}"; do
  eventually "200 $path" status_is "$base$path" 200 "${smoke[@]}"
  eventually "$path is canonical and linked from /plugins/" plugin_page_ok "$path"
  expect_redirect "${path%/}" "$path"
done
eventually '404 /plugins/<unknown slug>/' status_is "$base/plugins/no-such-plugin/" 404 "${smoke[@]}"
expect_redirect /robots.txt/ /robots.txt
expect_redirect /sitemaps/pages.xml/ /sitemaps/pages.xml

# Legacy URLs go straight to their page.
for legacy in privacy terms refunds; do
  expect_redirect "/$legacy" "/legal/$legacy/"
  expect_redirect "/$legacy/" "/legal/$legacy/"
done
expect_redirect /sitemap.xml /sitemap-index.xml

# /download/ has no page: it sends a temporary 302 (never a 308, which browsers keep) to the
# current DMG from latest.json, with no-store, so it always gives the latest build. The Download
# buttons on / and /thanks/ (the header, the home-page CTAs, and the /thanks/ button) go to the same
# DMG directly. A release published between two requests can change it, so these retry.
dmg_url='https://updates\.keybumps\.app/releases/[0-9]+/Keybumps-[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?\.dmg'
dmg=''
download_redirects_to_dmg() {
  local headers status location cache
  headers="$(curl -s "${limits[@]}" "${smoke[@]}" -o /dev/null -D - "$base/download/" || true)"
  headers="${headers//$'\r'/}"
  status="$(head -1 <<<"$headers" | awk '{print $2}')"
  location="$(grep -i '^location:' <<<"$headers" | head -1 | sed 's/^[^:]*: *//' || true)"
  cache="$(grep -i '^cache-control:' <<<"$headers" | head -1 || true)"
  if [ "$status" != 302 ] || ! grep -qE "^$dmg_url\$" <<<"$location" ||
    ! grep -qi 'no-store' <<<"$cache"; then
    why="got '$status' to '$location' with '${cache:-no Cache-Control}'"
    return 1
  fi
  dmg="$location"
}
eventually '302 /download/ -> the current DMG, not cached' download_redirects_to_dmg
# links_to_dmg <path> <count>: at least <count> links to a DMG, all of them to $dmg, and none to
# /download/.
links_to_dmg() {
  local body links
  body="$(fetch "$1")"
  links="$(grep -oE "href=\"$dmg_url\"" <<<"$body" || true)"
  if [ -z "$dmg" ] || [ "$(grep -c . <<<"$links")" -lt "$2" ] ||
    grep -vqF "href=\"$dmg\"" <<<"$links" || grep -q 'href="/download/"' <<<"$body"; then
    why="want $2+ links to '$dmg', got '$(sort -u <<<"$links" | tr '\n' ' ')'"
    return 1
  fi
}
eventually 'download buttons on / link to the current DMG (the 302 target)' links_to_dmg / 3
eventually 'download buttons on /thanks/ link to the current DMG (the 302 target)' \
  links_to_dmg /thanks/ 2

# Sitemaps list only canonical URLs: child sitemaps are unslashed files, pages end in a slash.
# sitemap_is_canonical <path> <loc regex>
sitemap_is_canonical() {
  local locs
  locs="$(grep -oE '<loc>[^<]+</loc>' <<<"$(fetch "$1")" || true)"
  if [ -z "$locs" ]; then
    why='no URLs'
    return 1
  fi
  if grep -vqE "$2" <<<"$locs"; then
    why="non-canonical URL $(grep -vE "$2" <<<"$locs" | head -1 || true)"
    return 1
  fi
}
eventually 'sitemap index lists unslashed .xml files on keybumps.app' \
  sitemap_is_canonical /sitemap-index.xml '^<loc>https://keybumps\.app/[^<]*\.xml</loc>$'
eventually 'pages sitemap lists slashed page URLs on keybumps.app' \
  sitemap_is_canonical /sitemaps/pages.xml '^<loc>https://keybumps\.app/([^<]*/)?</loc>$'

# Unmatched URLs render the global 404 (experimental globalNotFound, since the site has two root
# layouts): status 404, noindex, no referrer, and never analytics, even with a checkout query.
missing='/thanks/x/?customer_session_token=x'
missing_page=''
not_found_page() {
  local status
  status="$(curl -s "${limits[@]}" "${smoke[@]}" -o /dev/null -w '%{http_code}' "$base$missing" || true)"
  missing_page="$(fetch "$missing")"
  if [ "$status" = 404 ] && grep -q '<meta name="robots" content="noindex' <<<"$missing_page" &&
    grep -q '<meta name="referrer" content="no-referrer"' <<<"$missing_page" &&
    ! grep -q 'googletagmanager' <<<"$missing_page"; then
    return 0
  fi
  why="$missing gave $status or the wrong 404 page"
  return 1
}
eventually '404 page for unknown paths (noindex, no-referrer, no GTM)' not_found_page

# /thanks/ and /license/ never render with a query: Polar's checkout and customer-session
# parameters are redirected away before the page renders (src/lib/sensitive-url.ts), so neither
# the page nor analytics ever holds them. The query values are placeholders. The 404, which can't
# redirect, strips its query in <head> (src/components/strip-query.tsx).
for path in /thanks/ /license/; do
  eventually "307 $path?customer_session_token=… -> $path" \
    status_is "$base$path?checkout_id=x&customer_session_token=x" "307 $base$path" "${smoke[@]}"
  # Client-side navigation can't reach them: RSC requests 404, and the router then does a full
  # page load (src/lib/sensitive-url-routes.ts).
  eventually "RSC request for $path gets 404 (full page loads only)" \
    status_is "$base$path" 404 "${smoke[@]}" -H 'rsc: 1'
done
eventually '404 page strips its query in <head>' \
  body_matches "$missing" 'window\.history\.replaceState\(window\.history\.state'

# The pages name src/app/opengraph-image.jpg with a hand-copied cache key (src/lib/metadata.ts).
# The 404 gets the key Next.js generates, so the two must match, or the copy went stale.
og_image() { grep -oE '<meta property="og:image" content="[^"]*"' <<<"$1" | head -1 || true; }
missing_og=''
og_key_current() {
  local home_og
  home_og="$(og_image "$(fetch /)")"
  missing_og="$(og_image "$(fetch "$missing")")"
  if [ -z "$home_og" ] || [ "$home_og" != "$missing_og" ]; then
    why="stale: pages have '$home_og', Next.js generates '$missing_og'"
    return 1
  fi
}
eventually 'og:image cache key matches the generated one' og_key_current
# Every key page keeps that image: Next.js replaces a layout's openGraph when a page sets one.
og_on() {
  local page_og
  page_og="$(og_image "$(fetch "$1")")"
  if [ -z "$missing_og" ] || [ "$page_og" != "$missing_og" ]; then
    why="got '$page_og' (want '$missing_og')"
    return 1
  fi
}
for path in /plugins/ /plugins/timer/ /pricing/ /license/ /thanks/ /about/ /legal/privacy/ \
  /sitemap/; do
  eventually "og:image on $path" og_on "$path"
done

gtm='googletagmanager\.com/gtm\.js'
if [ "$env" = production ]; then
  eventually 'robots.txt allows crawling' body_matches /robots.txt '^Allow: /$'
  eventually 'robots.txt lists the sitemap index' \
    body_matches /robots.txt '^Sitemap: https://keybumps\.app/sitemap-index\.xml$'
  eventually 'no X-Robots-Tag' robots_header_is none
  eventually 'no robots noindex meta on /' body_lacks / '<meta name="robots" content="noindex'
  # GTM loads on ordinary pages, and on /thanks/ and /license/ too: those never render with a
  # query (the 307 checks above). GTM needs NEXT_PUBLIC_GTM_ID in the build and SITE_ENV=production
  # in the Worker's vars, because the layout renders on request.
  eventually 'GTM loads on / (needs NEXT_PUBLIC_GTM_ID in the build and SITE_ENV in the Worker)' \
    body_matches / "$gtm"
  for path in /thanks/ /license/; do
    eventually "GTM loads on $path" body_matches "$path" "$gtm"
  done
else
  eventually 'robots.txt disallows crawling' body_matches /robots.txt '^Disallow: /$'
  eventually 'X-Robots-Tag noindex' robots_header_is noindex
  # CI builds staging with a placeholder GTM ID, so this checks the SITE_ENV gate itself.
  eventually 'no GTM on /' body_lacks / "$gtm"
fi

# Non-canonical hosts redirect to the canonical host in one 308, already in canonical form: a page
# keeps its path, and a legacy URL goes straight to its page. A new deploy can take a few seconds
# to replace the previous version at the edge, so these retry for longer.
# usage: expect_host_redirect <label> <canonical-origin> <url> [curl options...]
expect_host_redirect() {
  local label="$1" origin="$2" url="$3" tries=10
  shift 3
  eventually "$label 308 /legal/terms/ -> $origin/legal/terms/" \
    status_is "$url/legal/terms/" "308 $origin/legal/terms/" "$@"
  eventually "$label 308 /privacy -> $origin/legal/privacy/" \
    status_is "$url/privacy" "308 $origin/legal/privacy/" "$@"
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
    workers_dev=(-H 'Host: keybumps-web.example.workers.dev')
    expect_host_redirect www https://keybumps.app "$base" -H 'Host: www.keybumps.app'
    expect_host_redirect workers.dev "$canonical" "$base" "${workers_dev[@]}"
    eventually 'workers.dev with the smoke-test header serves the site' \
      status_is "$base/legal/terms/" 200 "${smoke[@]}" "${workers_dev[@]}"
    ;;
  *)
    echo "skip host redirects: no www or workers.dev host to check through $base"
    ;;
esac

exit "$failed"
