import type { MetadataRoute } from 'next'
import { absoluteUrl, isProductionSite } from '@/lib/site'

export default function robots(): MetadataRoute.Robots {
  if (!isProductionSite()) return { rules: { userAgent: '*', disallow: '/' } }
  return {
    rules: { userAgent: '*', allow: '/' },
    sitemap: absoluteUrl('/sitemap-index.xml')
  }
}
