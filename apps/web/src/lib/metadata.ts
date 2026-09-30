import type { Metadata } from 'next'
import { pageFor, type SitePagePath } from './pages'
import { site } from './site'

/**
 * The social preview image, src/app/opengraph-image.jpg. That file sits above the route groups,
 * and with no shared root layout Next.js no longer attaches it to grouped pages, so the site names
 * it here with the URL and cache key Next.js generates for it (the global 404 still gets the
 * generated one). scripts/smoke.sh fails if the two differ, so update this when the image changes.
 */
export const openGraphImage = {
  url: '/opengraph-image.jpg?opengraph-image.0-pf82j9iav8s.jpg',
  type: 'image/jpeg',
  width: 1200,
  height: 630
}

/**
 * Open Graph defaults for every page. Next.js replaces, rather than merges, a parent's
 * `openGraph` when a page sets its own, so pages spread these in. Title and description are left
 * out so Next.js fills them from the page's resolved title and description.
 */
export const defaultOpenGraph = {
  siteName: site.name,
  type: 'website',
  locale: 'en_US',
  images: [openGraphImage]
} satisfies Metadata['openGraph']

/** The Open Graph defaults without the image, for the global 404 (see openGraphImage). */
export const openGraphWithoutImage = {
  siteName: defaultOpenGraph.siteName,
  type: defaultOpenGraph.type,
  locale: defaultOpenGraph.locale
} satisfies Metadata['openGraph']

/** Metadata shared by both root layouts and the global 404. */
export const siteMetadata: Metadata = {
  metadataBase: new URL(site.url),
  title: {
    default: 'Keybumps — Six Mac utilities, one shortcut away',
    template: `%s — ${site.name}`
  },
  description: site.description
}

/** Root layout metadata: the shared metadata plus the Open Graph defaults. */
export const rootLayoutMetadata: Metadata = { ...siteMetadata, openGraph: defaultOpenGraph }

/** Title, description, canonical URL, and Open Graph for a static page. */
export function pageMetadata(path: SitePagePath): Metadata {
  const page = pageFor(path)
  return {
    title: page.title,
    description: page.description,
    alternates: { canonical: path },
    openGraph: { ...defaultOpenGraph, url: path }
  }
}
