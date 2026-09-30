import type { Rewrite } from 'next/dist/lib/load-custom-routes'
import { sensitiveUrlPaths } from './pages'

/**
 * The App Router sends this header, with the value `1`, on every client-side navigation, prefetch,
 * and refresh request (RSC requests). Browsers never send it on a document request.
 */
export const rscHeader = 'rsc'

/** A path no page serves (`_` folders are private in the App Router), so it always 404s. */
export const fullLoadOnlyPath = '/_full-load-only'

/**
 * Rewrites every RSC request for a (sensitive-url) page to a 404, so the App Router can never
 * reach those pages client-side, with or without a query. For a navigation, a non-OK RSC
 * response makes the router fall back to a full page load of the URL, which the page then
 * redirects without its query before rendering (src/lib/sensitive-url.ts). The router never
 * commits the URL, so it never writes it to the address bar or history, and GTM's history-change
 * listener never sees it. A prefetch just fails.
 *
 * Without this, `<Link href="/license/?…">` or `router.push('/license/?…')` from /thanks/ is a
 * soft navigation inside one root layout: the page's `redirect()` then arrives inside the RSC
 * payload, after the router has already pushed the URL with its query.
 */
export function sensitiveUrlRewrites(): Rewrite[] {
  return sensitiveUrlPaths.map(path => ({
    source: path,
    has: [{ type: 'header', key: rscHeader }],
    destination: fullLoadOnlyPath
  }))
}
