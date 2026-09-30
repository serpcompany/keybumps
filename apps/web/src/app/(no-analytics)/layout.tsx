import { rootLayoutMetadata, SiteDocument } from '@/components/site-document'

export const metadata = rootLayoutMetadata

/**
 * Root layout for pages whose URLs can carry checkout, session, or license data (/thanks/,
 * /license/; `noAnalyticsPaths` in src/lib/pages.ts). It never renders analytics, and because it
 * is a separate root layout, every navigation into or out of these pages is a full page load.
 */
export default function NoAnalyticsRootLayout({ children }: LayoutProps<'/'>) {
  return <SiteDocument>{children}</SiteDocument>
}
