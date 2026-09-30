import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { buildCustomRoute } from 'next/dist/lib/build-custom-route'
import { describe, expect, it } from 'vitest'
import { sensitiveUrlPaths, sitePages } from './pages'
import { fullLoadOnlyPath, rscHeader, sensitiveUrlRewrites } from './sensitive-url-routes'

/** Where a request is rewritten to, matched the way Next.js and OpenNext match a rewrite. */
function rewrite(path: string, headers: Record<string, string> = {}) {
  for (const rule of sensitiveUrlRewrites()) {
    const route = buildCustomRoute('rewrite', rule)
    if (!new RegExp(route.regex).test(path)) continue
    const has = rule.has ?? []
    if (!has.every(condition => condition.type === 'header' && condition.key in headers)) continue
    return rule.destination
  }
  return null
}

describe('sensitive-url rewrites', () => {
  it('sends every RSC request for a sensitive-url page to a 404', () => {
    // The unslashed form (/thanks) first takes the site's trailing-slash 308, which runs before
    // rewrites; the browser follows it with the same headers (redirects.test.ts covers the 308).
    for (const path of sensitiveUrlPaths) {
      expect(rewrite(path, { [rscHeader]: '1' }), path).toBe(fullLoadOnlyPath)
    }
  })

  it('leaves document requests and every other page alone', () => {
    const sensitive: readonly string[] = sensitiveUrlPaths
    for (const path of sensitiveUrlPaths) expect(rewrite(path), path).toBeNull()
    for (const page of sitePages.filter(page => !sensitive.includes(page.path))) {
      expect(rewrite(page.path, { [rscHeader]: '1' }), page.path).toBeNull()
    }
  })

  it('rewrites to a path no page can serve', () => {
    // `_` folders are private in the App Router, so this always renders the 404.
    expect(fullLoadOnlyPath).toMatch(/^\/_/)
  })
})

/** The installed Next.js client source, to check the internals the rewrite relies on. */
const nextClient = join(
  __dirname,
  '..',
  '..',
  'node_modules',
  'next',
  'dist',
  'client',
  'components'
)
const clientSource = (file: string) => readFileSync(join(nextClient, file), 'utf8')

describe('the Next.js internals the rewrite relies on (re-check on every upgrade)', () => {
  it('matches the header name Next.js defines, in lower case as OpenNext compares it', () => {
    expect(clientSource('app-router-headers.js')).toMatch(/const RSC_HEADER = 'rsc';/)
    expect(rscHeader).toBe(rscHeader.toLowerCase())
  })

  it('sets the header on every flight request the client router sends', () => {
    // Navigations and refreshes (fetchServerResponse) and every prefetch (segment cache) build
    // their headers with RSC_HEADER; a header object with a router header but no RSC_HEADER fails.
    for (const file of ['router-reducer/fetch-server-response.js', 'segment-cache/cache.js']) {
      const source = clientSource(file)
      const headerObjects =
        source.match(/\{[^{}]*_approuterheaders\.NEXT_ROUTER_[A-Z_]+_HEADER\]:[^{}]*\}/g) ?? []
      expect(headerObjects.length, file).toBeGreaterThan(0)
      for (const object of headerObjects) {
        expect(object, file).toContain("[_approuterheaders.RSC_HEADER]: '1'")
      }
    }
  })

  it('turns a non-OK RSC response into a full page load', () => {
    const source = clientSource('router-reducer/fetch-server-response.js')
    expect(source).toMatch(
      /if \(!isFlightResponse \|\| !res\.ok \|\| !res\.body\) \{[\s\S]{0,400}?return doMpaNavigation\(/
    )
  })
})
