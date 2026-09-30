import { Analytics } from '@/components/analytics'
import { SiteDocument } from '@/components/site-document'
import { StripQuery } from '@/components/strip-query'
import { sensitiveUrlLayoutMetadata } from '@/lib/metadata'

export const metadata = sensitiveUrlLayoutMetadata

/**
 * Root layout for pages whose URLs can carry checkout, session, or license data (/thanks/,
 * /license/; `sensitiveUrlPaths` in src/lib/pages.ts). The pages redirect a request with a query
 * before rendering (src/lib/sensitive-url.ts). As a second layer, `<StripQuery />` removes any query
 * in `<head>`: not first there, but before the browser parses `<body>`, so before the App Router
 * can start (it needs the RSC payload in `<body>`) and before `<Analytics />` loads GTM after
 * hydration. These pages are only ever reached by full page loads: this is a separate root layout,
 * and every RSC request for them is rewritten to a 404 (src/lib/sensitive-url-routes.ts). It also
 * sends no Referer. src/lib/analytics-scope.test.ts enforces this.
 */
export default function SensitiveUrlRootLayout({ children }: LayoutProps<'/'>) {
  return (
    <SiteDocument head={<StripQuery />}>
      {children}
      <Analytics />
    </SiteDocument>
  )
}
