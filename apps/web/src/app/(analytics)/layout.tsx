import { Analytics } from '@/components/analytics'
import { SiteDocument } from '@/components/site-document'
import { rootLayoutMetadata } from '@/lib/metadata'

export const metadata = rootLayoutMetadata

/**
 * Root layout for ordinary pages. It loads analytics without touching the URL, so campaign
 * parameters reach GTM. Pages whose URLs can carry checkout, session, or license data (/thanks/,
 * /license/) use the separate (sensitive-url) root layout instead, which strips the query before
 * GTM loads. Moving between different root layouts is always a full page load, so a document
 * that is already running GTM never shows those URLs through client-side navigation or the Back
 * button. src/lib/analytics-scope.test.ts enforces this.
 */
export default function AnalyticsRootLayout({ children }: LayoutProps<'/'>) {
  return (
    <SiteDocument>
      {children}
      <Analytics />
    </SiteDocument>
  )
}
