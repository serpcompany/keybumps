/**
 * The inline script StripQuery renders. If the URL has a query string, it replaces the current
 * history entry's URL with the path and hash, passing the entry's state through. If that ever
 * throws, it stops parsing the page (so the router never starts and GTM never loads) and reloads
 * the page without the query. Exported for tests.
 */
export const stripQueryScript = `(function () {
  var l = window.location
  if (!l.search) return
  var url = l.pathname + l.hash
  try {
    window.history.replaceState(window.history.state, '', url)
  } catch (e) {
    window.stop()
    l.replace(url)
  }
})()`

/**
 * Removes the query string from the address bar and the current history entry before the App
 * Router starts and before GTM loads. The (sensitive-url) root layout and the global 404 render it
 * in `<head>` (through SiteDocument's `head`): Polar appends checkout and customer-session
 * parameters to /thanks/, and a mistyped URL can carry them to the 404.
 *
 * On (sensitive-url) pages it is the second layer: those pages redirect a request with a query
 * before rendering (src/lib/sensitive-url.ts), so normally there is nothing to strip. On the 404,
 * which never loads analytics, it keeps the query out of the address bar and later Referers.
 *
 * It does not run first in `<head>`: React and Next.js hoist the stylesheet, the async framework
 * chunks, the `gtm.js` preload, and the metadata tags above it. Why it still runs in time, by
 * structure rather than a race: it is a parser-inserted classic inline script in `<head>`, so it
 * runs before the browser parses `<body>`. An async chunk may run earlier, but the App Router
 * can't start until it has the page's RSC payload, which is inline in `<body>`, so the router
 * reads `location` only after the strip. GTM is inserted by the Analytics component in an effect
 * after hydration, later still. The `gtm.js` preload only fetches the script. The strip passes
 * the entry's state through, and the router writes its own state afterwards, so Back and Forward
 * keep working. (The router's state also takes the tree and search from the server's payload,
 * which is why the pages redirect instead of relying on this alone.)
 *
 * It runs once per document. That is enough because the App Router never renders (sensitive-url)
 * pages client-side: every RSC request for them is rewritten to a 404, and Next.js 16.3 turns that
 * into a full page load (src/lib/sensitive-url-routes.ts, which describes the two router paths
 * and why `pnpm test:leak` must pass on every Next.js or OpenNext upgrade).
 */
export function StripQuery() {
  // A constant script, not user input. Only an inline script runs before the parser reaches <body>.
  // biome-ignore lint/security/noDangerouslySetInnerHtml: see above.
  return <script dangerouslySetInnerHTML={{ __html: stripQueryScript }} />
}
