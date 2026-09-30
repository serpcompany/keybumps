import { describe, expect, it } from 'vitest'
import { defaultOpenGraph, openGraphImage, pageMetadata, rootLayoutMetadata } from './metadata'
import { sitePages } from './pages'

describe('page metadata', () => {
  it('keeps the shared Open Graph image and site details on every page', () => {
    // Next.js replaces a parent's openGraph when a page sets one, so each page must carry these.
    for (const page of sitePages) {
      const { openGraph, alternates } = pageMetadata(page.path)
      expect(openGraph, page.path).toMatchObject({ ...defaultOpenGraph, url: page.path })
      expect(openGraph?.images, page.path).toEqual([openGraphImage])
      expect(alternates?.canonical, page.path).toBe(page.path)
    }
  })

  it('gives both root layouts the shared Open Graph image', () => {
    expect(rootLayoutMetadata.openGraph).toEqual(defaultOpenGraph)
  })

  it('points at the file-based image route', () => {
    expect(openGraphImage.url).toMatch(/^\/opengraph-image\.jpg\?opengraph-image\.[\w-]+\.jpg$/)
  })
})
