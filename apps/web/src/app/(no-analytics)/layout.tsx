import type { Metadata } from 'next'
import { SiteDocument } from '@/components/site-document'
import { StripQuery } from '@/components/strip-query'
import { rootLayoutMetadata } from '@/lib/metadata'

export const metadata: Metadata = {
  ...rootLayoutMetadata,
  // These URLs can carry checkout, session, or license data; never send them on as a Referer.
  referrer: 'no-referrer'
}

/**
 * Root layout for pages whose URLs can carry checkout, session, or license data (/thanks/,
 * /license/; `noAnalyticsPaths` in src/lib/pages.ts). It never renders analytics, and because it
 * is a separate root layout, every navigation into or out of these pages is a full page load. It
 * also sends no Referer and strips the query string from the address bar once the page renders.
 */
export default function NoAnalyticsRootLayout({ children }: LayoutProps<'/'>) {
  return (
    <SiteDocument>
      <StripQuery />
      {children}
    </SiteDocument>
  )
}
