import { childSitemaps, sitemapIndexXml, xmlResponse } from '@/lib/sitemap'

export const dynamic = 'force-static'

export function GET() {
  return xmlResponse(sitemapIndexXml(childSitemaps))
}
