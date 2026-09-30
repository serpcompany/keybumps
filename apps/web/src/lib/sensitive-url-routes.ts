import { RSC_HEADER } from 'next/dist/client/components/app-router-headers'
import type { Rewrite } from 'next/dist/lib/load-custom-routes'
import { sensitiveUrlPaths } from './pages'

/**
 * The header the App Router sends, with the value `1`, on every client-side navigation, prefetch,
 * and refresh request (RSC requests). Browsers never send it on a document request. Taken from
 * Next.js itself, so a rename follows; sensitive-url-routes.test.ts also checks the installed
 * client source sets it on every flight request.
 */
export const rscHeader = RSC_HEADER

/** A path no page serves (`_` folders are private in the App Router), so it always 404s. */
export const fullLoadOnlyPath = '/_full-load-only'

/**
 * Rewrites every RSC request for a (sensitive-url) page to a 404, so the App Router never renders
 * those pages client-side. Without it, a client-side navigation to /license/?… would get the
 * page's `redirect()` inside a 200 RSC payload, after the router had pushed the URL.
 *
 * Next.js 16.3 turns a non-OK RSC response into a full page load (`doMpaNavigation` in
 * `fetchServerResponse`), which the page then redirects without its query. It gets there two ways:
 * - Unknown route (another page, or one the router hasn't learned): the router awaits the fetch
 *   before committing, gets the 404, and does a hard navigation (`completeHardNavigation`, then
 *   `location.assign` during render). Nothing is ever committed.
 * - Known route, same pathname with a new query (for example /thanks/ → /thanks/?…): the router
 *   predicts the route and starts a soft navigation first, then the dynamic request 404s and it
 *   dispatches a hard navigation (`ACTION_SERVER_PATCH` with `mpa`). Nothing is pushed only because
 *   the soft navigation's transition is still suspended on the missing page data (Next's comment
 *   in `ppr-navigations.js`: "Otherwise, the pushState already ran").
 * Both are Next.js internals, so `pnpm test:leak` must pass on every Next.js or OpenNext upgrade.
 *
 * This keeps a URL with a query out of the address bar, history, and GTM's history-change
 * trigger. It does not make a link with a query safe: GTM's click triggers push the clicked `href`
 * (`gtm.elementUrl`), and tag code in the old document can read the RSC request URL. So nothing may
 * link to these pages with a query (src/lib/analytics-scope.test.ts), and links to them set
 * `prefetch={false}`, so page views don't send RSC requests that 404.
 */
export function sensitiveUrlRewrites(): Rewrite[] {
  return sensitiveUrlPaths.map(path => ({
    source: path,
    has: [{ type: 'header', key: rscHeader }],
    destination: fullLoadOnlyPath
  }))
}
