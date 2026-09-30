import type { Redirect } from 'next/dist/lib/load-custom-routes'
import { legacyRedirects } from './pages'

export const productionOrigin = 'https://keybumps.app'
export const stagingOrigin = 'https://staging.keybumps.app'

/**
 * CI smoke tests send this header to reach a Worker on its workers.dev URL, because the zone's bot
 * protection blocks CI runners on the branded domain. It is not a secret: it only reveals the same
 * public site on another host, and search engines never send it.
 */
export const smokeTestHeader = 'x-keybumps-smoke-test'

type RouteCondition = NonNullable<Redirect['has']>[number]

// Host values are regexes. Next.js anchors them but OpenNext tests them unanchored, so anchor and
// escape them here to match exactly these hosts on both.
const wwwHost = { type: 'host', value: '^www\\.keybumps\\.app$' } as const
const workersDevHost = { type: 'host', value: '^(?<worker>.+)\\.workers\\.dev$' } as const
const smokeTest = { type: 'header', key: smokeTestHeader } as const

// Next.js lets every custom redirect source match with or without a trailing slash, so a page
// pattern has to refuse slashed paths itself, or /about/ would redirect to itself. Paths whose
// segments start with `_` (/_next/, Next.js dev endpoints) are never pages.
const unslashedPage = '(?:(?!_|.*/$)[^/.]+)'
const pageDirectory = '(?:(?!_|\\.well-known/)[^/]+)'
const file = '[^/]+\\.\\w+'

/**
 * Same-host canonical URL rules (SERP URL trailing-slash standard): legacy URLs go straight to
 * their page, files lose a trailing slash, and pages gain one, each in a single 308.
 *
 * `skipTrailingSlashRedirect` turns off the framework's own trailing-slash redirect, because
 * OpenNext runs it before any custom redirect: /privacy would take two hops (/privacy/, then
 * /legal/privacy/). These rules replace it. Two rules per shape, because OpenNext cannot fill an
 * empty path parameter or a parameter that spans several segments.
 */
export function canonicalPathRedirects(): Redirect[] {
  return [
    ...legacyRedirects.map(({ from, to }) => ({ source: from, destination: to, permanent: true })),
    // Crawlers look for /sitemap.xml by default.
    { source: '/sitemap.xml', destination: '/sitemap-index.xml', permanent: true },
    { source: `/:file(${file})/`, destination: '/:file', permanent: true },
    {
      source: `/:dir(${pageDirectory})+/:file(${file})/`,
      destination: '/:dir+/:file',
      permanent: true
    },
    { source: `/:page(${unslashedPage})`, destination: '/:page/', permanent: true },
    {
      source: `/:dir(${pageDirectory})+/:page(${unslashedPage})`,
      destination: '/:dir+/:page/',
      permanent: true
    }
  ]
}

/**
 * Redirects every path on the matching host to `origin` in one hop, already in canonical form:
 * legacy URLs go to their page, pages keep or gain their trailing slash, and files never get one.
 * Files come before pages because `/:path+` also matches them, and `/` has its own rule because
 * OpenNext cannot fill an empty path. Next.js lets each source match with or without a trailing
 * slash, so `/:path+` covers both /about and /about/.
 */
export function redirectHostTo(
  origin: string,
  has: RouteCondition[],
  missing: RouteCondition[] = []
): Redirect[] {
  const rule = (source: string, destination: string): Redirect => ({
    source,
    has,
    ...(missing.length ? { missing } : {}),
    destination: `${origin}${destination}`,
    permanent: true
  })
  return [
    ...legacyRedirects.map(({ from, to }) => rule(from, to)),
    rule('/', '/'),
    rule(`/:file(${file})`, '/:file'),
    rule(`/:dir+/:file(${file})`, '/:dir+/:file'),
    rule('/:path+', '/:path+/')
  ]
}

/** Every redirect the site serves, in the order Next.js and OpenNext must check them. */
export function siteRedirects({ production }: { production: boolean }): Redirect[] {
  return [
    // A workers.dev URL redirects to its environment's branded domain, except for CI smoke tests.
    ...redirectHostTo(production ? productionOrigin : stagingOrigin, [workersDevHost], [smokeTest]),
    // www serves the production Worker and always redirects to the apex.
    ...redirectHostTo(productionOrigin, [wwwHost]),
    ...canonicalPathRedirects()
  ]
}
