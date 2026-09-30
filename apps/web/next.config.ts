import { initOpenNextCloudflareForDev } from '@opennextjs/cloudflare'
import type { NextConfig } from 'next'
import { siteRedirects } from './src/lib/redirects'
import { isProductionSite } from './src/lib/site'

const nextConfig: NextConfig = {
  images: { unoptimized: true },
  // SERP URL trailing-slash standard: pages end in / (/about/); files never do (/robots.txt).
  trailingSlash: true,
  // The trailing-slash redirects live in siteRedirects() instead, so legacy URLs such as /privacy
  // reach their page in one hop. See src/lib/redirects.ts.
  skipTrailingSlashRedirect: true,
  turbopack: {
    // Keep lockfiles outside apps/web from changing the workspace root.
    root: process.cwd()
  },
  async redirects() {
    return siteRedirects({ production: isProductionSite() })
  },
  async headers() {
    if (isProductionSite()) return []
    return [{ source: '/:path*', headers: [{ key: 'X-Robots-Tag', value: 'noindex, nofollow' }] }]
  }
}

export default nextConfig

// Lets `next dev` read Cloudflare bindings through getCloudflareContext().
initOpenNextCloudflareForDev()
