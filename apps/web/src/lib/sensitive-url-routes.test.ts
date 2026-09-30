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
