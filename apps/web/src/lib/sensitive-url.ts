import { redirect } from 'next/navigation'
import type { SensitiveUrlPath } from './pages'

/**
 * Redirects a request for a (sensitive-url) page that carries a query string to the same page
 * without it, before the page renders. Every (sensitive-url) page calls it first.
 *
 * The site renders pages on the Worker at request time, and Next.js puts the request's query into
 * the page's RSC payload (the canonical URL, the rendered search, and the page segment key). The
 * App Router copies that into `history.state`, which GTM's history-change trigger pushes to the
 * `dataLayer`. So stripping the address bar alone isn't enough: the page must never render with
 * the query. A redirect also replaces the history entry, so Back never returns to the query.
 * StripQuery in `<head>` stays as the second layer, for any response that skips this.
 */
export async function redirectWithoutQuery(
  path: SensitiveUrlPath,
  searchParams: Promise<Record<string, string | string[] | undefined>>
) {
  if (Object.keys(await searchParams).length > 0) redirect(path)
}
