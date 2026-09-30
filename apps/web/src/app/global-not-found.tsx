import type { Metadata } from 'next'
import { PageShell } from '@/components/page-shell'
import { SiteDocument, siteMetadata } from '@/components/site-document'

// The site has two root layouts and no shared one, so unmatched URLs need their own document.
// It never renders analytics: a 404 URL can still carry a mistyped checkout or session query.
export const metadata: Metadata = {
  ...siteMetadata,
  title: { absolute: '404: This page could not be found.' }
}

export default function GlobalNotFound() {
  return (
    <SiteDocument>
      <PageShell title="404">
        <p>This page could not be found.</p>
      </PageShell>
    </SiteDocument>
  )
}
