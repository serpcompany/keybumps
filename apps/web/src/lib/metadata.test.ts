import type { Metadata } from 'next'
import { describe, expect, it } from 'vitest'
import { metadata as homeMetadata } from '@/app/(analytics)/page'
import { metadata as thanksMetadata } from '@/app/(sensitive-url)/thanks/page'
import {
  defaultOpenGraph,
  notFoundMetadata,
  openGraphImage,
  openGraphWithoutImage,
  pageMetadata,
  rootLayoutMetadata,
  sensitiveUrlLayoutMetadata
} from './metadata'
import { sitePages } from './pages'

/**
 * The Open Graph a page ends up with: Next.js replaces the layout's `openGraph` when the page
 * sets its own, and inherits it otherwise. Twitter tags follow Open Graph unless a page sets them.
 */
function effectiveOpenGraph(page: Metadata, layout: Metadata) {
  return page.openGraph ?? layout.openGraph
}

function expectSharedOpenGraph(page: Metadata, layout: Metadata, name: string) {
  const openGraph = effectiveOpenGraph(page, layout)
  expect(openGraph, name).toMatchObject(defaultOpenGraph)
  expect(openGraph?.images, name).toEqual([openGraphImage])
  expect(page.twitter, `${name} must not replace the Twitter card`).toBeUndefined()
}

describe('page metadata', () => {
  it('keeps the shared Open Graph image and site details on every pageMetadata() page', () => {
    for (const page of sitePages) {
      const metadata = pageMetadata(page.path)
      expectSharedOpenGraph(metadata, rootLayoutMetadata, page.path)
      expect(metadata.openGraph, page.path).toMatchObject({ url: page.path })
      expect(metadata.alternates?.canonical, page.path).toBe(page.path)
    }
  })

  it('keeps them on the pages with their own metadata: / and /thanks/', () => {
    expectSharedOpenGraph(homeMetadata, rootLayoutMetadata, '/')
    expectSharedOpenGraph(thanksMetadata, sensitiveUrlLayoutMetadata, '/thanks/')
  })

  it('keeps the sensitive-url layout on the shared metadata, with no referrer', () => {
    expect(sensitiveUrlLayoutMetadata).toMatchObject({
      ...rootLayoutMetadata,
      referrer: 'no-referrer'
    })
  })

  it('gives the 404 the site details and no referrer, leaving the image to Next.js', () => {
    // No explicit image: Next.js attaches src/app/opengraph-image.jpg with the generated cache key,
    // and scripts/smoke.sh fails if it differs from openGraphImage.
    expect(notFoundMetadata.openGraph).toEqual(openGraphWithoutImage)
    expect(notFoundMetadata.openGraph).toMatchObject({
      siteName: defaultOpenGraph.siteName,
      type: defaultOpenGraph.type,
      locale: defaultOpenGraph.locale
    })
    expect(notFoundMetadata.referrer).toBe('no-referrer')
    expect(notFoundMetadata.twitter).toBeUndefined()
  })

  it('points at the file-based image route', () => {
    expect(openGraphImage.url).toMatch(/^\/opengraph-image\.jpg\?opengraph-image\.[\w-]+\.jpg$/)
  })
})
