import { Analytics } from '@/components/analytics'

/**
 * Pages that may run analytics. Pages whose URLs can carry checkout, session, or license data
 * (/thanks/, /license/) live outside this group, so analytics never load on them, not even when
 * someone links to them with a query string. src/lib/analytics-scope.test.ts enforces this.
 */
export default function AnalyticsLayout({ children }: LayoutProps<'/'>) {
  return (
    <>
      {children}
      <Analytics />
    </>
  )
}
