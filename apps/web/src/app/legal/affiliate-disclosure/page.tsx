import { PageShell } from '@/components/page-shell'
import { pageMetadata } from '@/lib/metadata'

export const metadata = pageMetadata('/legal/affiliate-disclosure/')

export default function AffiliateDisclosurePage() {
  return (
    <PageShell title="Affiliate Disclosure" showUpdated>
      <p>
        keybumps.app does not contain affiliate links, and we earn no commission from anything
        linked on this site. If that changes, we will say so here and next to the affected links, as
        the U.S. Federal Trade Commission’s Guides Concerning the Use of Endorsements and
        Testimonials in Advertising (16 CFR Part 255) require.
      </p>
    </PageShell>
  )
}
