import { describe, expect, it } from 'vitest'
import { indexablePages, legacyRedirects, sitePages } from './pages'

describe('site pages', () => {
  it('uses the trailing-slash form for every page URL', () => {
    for (const page of sitePages) expect(page.path).toMatch(/\/$/)
  })

  it('lists each page once', () => {
    const paths = sitePages.map(page => page.path)
    expect(new Set(paths).size).toBe(paths.length)
  })

  it('sends every legacy URL to a listed page, and lists no legacy URL as a page', () => {
    // A plugin's page counts: ScreenGrabs' moved from /plugins/screenshot-tools/.
    const paths: string[] = indexablePages.map(page => page.path)
    for (const { from, to } of legacyRedirects) {
      expect(from).not.toMatch(/\/$/)
      expect(paths).toContain(to)
      expect(paths, from).not.toContain(`${from}/`)
    }
  })
})
