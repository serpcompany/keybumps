import { PageShell } from '@/components/page-shell'
import { pageMetadata } from '@/lib/metadata'
import { CUSTOMER_PORTAL_URL, SUPPORT_EMAIL } from '@/lib/site'

export const metadata = pageMetadata('/license/')

export default function LicensePage() {
  const portal = <a href={CUSTOMER_PORTAL_URL}>Polar customer portal</a>
  return (
    <PageShell title="Find your license key">
      <p>
        Your Keybumps license key is in the receipt email from Polar, our merchant of record. You
        can also sign in to the {portal} with the email address you used at checkout to see and copy
        it.
      </p>
      <p>
        <a href={CUSTOMER_PORTAL_URL} className="btn">
          Open the customer portal
        </a>
      </p>
      <h2>Moving to a new Mac</h2>
      <p>
        Your license covers one Mac. Open Keybumps on the old Mac, go to Settings → License, and
        choose Deactivate. If the old Mac is lost or wiped, deactivate it from the {portal}, or
        email <a href={`mailto:${SUPPORT_EMAIL}`}>{SUPPORT_EMAIL}</a>.
      </p>
    </PageShell>
  )
}
