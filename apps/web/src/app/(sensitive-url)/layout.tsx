import { Analytics } from '@/components/analytics'
import { SiteDocument } from '@/components/site-document'
import { StripQuery } from '@/components/strip-query'
import { sensitiveUrlLayoutMetadata } from '@/lib/metadata'

export const metadata = sensitiveUrlLayoutMetadata

/**
 * Root layout for pages whose URLs can carry checkout, session, or license data (/thanks/,
 * /license/; `sensitiveUrlPaths` in src/lib/pages.ts). `<StripQuery />` removes the query string
 * at the top of `<head>`, before the App Router starts and before `<Analytics />` can load GTM
 * after hydration, so GTM only ever sees the clean URL. Because this is a separate root layout,
 * every navigation into these pages from the rest of the site is a full page load, so the strip
 * always runs first in the new document. It also sends no Referer.
 * src/lib/analytics-scope.test.ts enforces this.
 */
export default function SensitiveUrlRootLayout({ children }: LayoutProps<'/'>) {
  return (
    <SiteDocument head={<StripQuery />}>
      {children}
      <Analytics />
    </SiteDocument>
  )
}
