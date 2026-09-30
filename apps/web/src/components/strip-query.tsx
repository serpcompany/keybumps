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
 * Removes the query string from the address bar and the current history entry before anything
 * else on the page runs. The (sensitive-url) root layout and the global 404 render it in `<head>`
 * (through SiteDocument's `head`): Polar appends checkout and customer-session parameters to
 * /thanks/, and a mistyped URL can carry them to the 404.
 *
 * On (sensitive-url) pages it is the second layer: those pages redirect a request with a query
 * before rendering (src/lib/sensitive-url.ts), so normally there is nothing to strip. On the 404,
 * which never loads analytics, it keeps the query out of the address bar and later Referers.
 *
 * Why the order is structural, not a race: this is a parser-inserted classic inline script, so
 * the browser runs it before it parses anything after it. The App Router hydrates from the RSC
 * payload in `<body>`, and GTM is inserted by the Analytics component in an effect after
 * hydration, so `location`, `document.URL`, and the router's URL are already clean when either
 * starts. It passes the entry's state through, and the router writes its own state afterwards, so
 * Back and Forward keep working. (The router's state also takes the tree and search from the
 * server's payload, which is why the pages redirect instead of relying on this alone.)
 *
 * It runs once per document, and the (sensitive-url) layout persists across client-side
 * navigation, so src/lib/analytics-scope.test.ts fails if a source file links to a
 * (sensitive-url) URL with a query.
 */
export function StripQuery() {
  // A constant script, not user input. Only an inline script runs before the parser continues.
  // biome-ignore lint/security/noDangerouslySetInnerHtml: see above.
  return <script dangerouslySetInnerHTML={{ __html: stripQueryScript }} />
}
