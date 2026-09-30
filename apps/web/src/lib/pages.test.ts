import { describe, expect, it } from 'vitest'
import { legacyRedirects, sitePages } from './pages'

describe('site pages', () => {
  it('uses the trailing-slash form for every page URL', () => {
    for (const page of sitePages) expect(page.path).toMatch(/\/$/)
  })

  it('lists each page once', () => {
    const paths = sitePages.map(page => page.path)
    expect(new Set(paths).size).toBe(paths.length)
  })

  it('sends every legacy URL to a listed page', () => {
    const paths: string[] = sitePages.map(page => page.path)
    for (const { from, to } of legacyRedirects) {
      expect(from).not.toMatch(/\/$/)
      expect(paths).toContain(to)
    }
  })
})
