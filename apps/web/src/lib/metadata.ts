import type { Metadata } from 'next'
import { pageFor, type SitePagePath } from './pages'

/** Title, description, and canonical URL for a static page. */
export function pageMetadata(path: SitePagePath): Metadata {
  const page = pageFor(path)
  return {
    title: page.title,
    description: page.description,
    alternates: { canonical: path },
    openGraph: { title: page.title, description: page.description, url: path }
  }
}
