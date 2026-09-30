import { absoluteUrl } from './site'

export type SitemapEntry = { url: string; lastModified?: Date }

function escapeXml(value: string) {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;')
}

function lastmod(date: Date | undefined) {
  return date ? `<lastmod>${date.toISOString()}</lastmod>` : ''
}

/** Child sitemaps listed by /sitemap-index.xml. Each holds at most 50,000 URLs. */
export const childSitemaps = ['/sitemaps/pages.xml'] as const

export function sitemapIndexXml(paths: readonly string[]) {
  const items = paths
    .map(path => `<sitemap><loc>${escapeXml(absoluteUrl(path))}</loc></sitemap>`)
    .join('')
  return `<?xml version="1.0" encoding="UTF-8"?><sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">${items}</sitemapindex>`
}

export function urlSetXml(entries: readonly SitemapEntry[]) {
  const items = entries
    .map(entry => `<url><loc>${escapeXml(entry.url)}</loc>${lastmod(entry.lastModified)}</url>`)
    .join('')
  return `<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">${items}</urlset>`
}

export function xmlResponse(body: string) {
  return new Response(body, {
    headers: {
      'Content-Type': 'application/xml; charset=utf-8',
      'Cache-Control': 'public, max-age=3600'
    }
  })
}
