import { PageShell } from '@/components/page-shell'
import { SiteDocument } from '@/components/site-document'
import { StripQuery } from '@/components/strip-query'
import { notFoundMetadata } from '@/lib/metadata'

// The site has two root layouts and no shared one, so unmatched URLs need their own document.
// It never renders analytics, sends no Referer, and strips the query string: a 404 URL can still
// carry a mistyped checkout or session query (for example /THANKS/?customer_session_token=…).
export const metadata = notFoundMetadata

export default function GlobalNotFound() {
  return (
    <SiteDocument head={<StripQuery />}>
      <PageShell title="404">
        <p>This page could not be found.</p>
      </PageShell>
    </SiteDocument>
  )
}
