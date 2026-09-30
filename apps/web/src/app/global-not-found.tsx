import type { Metadata } from 'next'
import { PageShell } from '@/components/page-shell'
import { SiteDocument } from '@/components/site-document'
import { openGraphWithoutImage, siteMetadata } from '@/lib/metadata'

// The site has two root layouts and no shared one, so unmatched URLs need their own document.
// It never renders analytics or sends a Referer: a 404 URL can still carry a mistyped checkout or
// session query. Its Open Graph image comes from src/app/opengraph-image.jpg, which Next.js
// attaches here with the generated cache key; scripts/smoke.sh compares it with openGraphImage.
export const metadata: Metadata = {
  ...siteMetadata,
  title: { absolute: '404: This page could not be found.' },
  // No explicit images: the generated opengraph-image.jpg entry is what smoke.sh compares against.
  openGraph: openGraphWithoutImage,
  referrer: 'no-referrer'
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
