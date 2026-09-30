import { Analytics } from '@/components/analytics'
import { rootLayoutMetadata, SiteDocument } from '@/components/site-document'

export const metadata = rootLayoutMetadata

/**
 * Root layout for pages that may run analytics. Pages whose URLs can carry checkout, session, or
 * license data (/thanks/, /license/) use the separate (no-analytics) root layout instead. Moving
 * between different root layouts is always a full page load, so GTM never keeps running into
 * those pages through client-side navigation or the Back button.
 * src/lib/analytics-scope.test.ts enforces this.
 */
export default function AnalyticsRootLayout({ children }: LayoutProps<'/'>) {
  return (
    <SiteDocument>
      {children}
      <Analytics />
    </SiteDocument>
  )
}
