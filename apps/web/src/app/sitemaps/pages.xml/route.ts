import { indexablePages } from '@/lib/pages'
import { absoluteUrl } from '@/lib/site'
import { urlSetXml, xmlResponse } from '@/lib/sitemap'

export const dynamic = 'force-static'

export function GET() {
  return xmlResponse(urlSetXml(indexablePages.map(page => ({ url: absoluteUrl(page.path) }))))
}
