import Link from 'next/link'
import { PageShell } from '@/components/page-shell'
import { pageMetadata } from '@/lib/metadata'
import { site } from '@/lib/site'

export const metadata = pageMetadata('/support/')

const link = 'underline underline-offset-4'

export default function SupportPage() {
  return (
    <PageShell title="Support">
      <p>
        For help with Keybumps, email{' '}
        <a href={`mailto:${site.supportEmail}`} className={link}>
          {site.supportEmail}
        </a>
        . Include your Mac model, your macOS version, and the Keybumps version.
      </p>
      <ul>
        <li>
          Lost your license key?{' '}
          <Link href="/license/" prefetch={false} className={link}>
            Find it in your receipt or the Polar customer portal
          </Link>
          .
        </li>
        <li>
          Want your money back?{' '}
          <Link href="/legal/refunds/" className={link}>
            Read the refund policy
          </Link>
          .
        </li>
        <li>
          Need the latest version?{' '}
          <Link href="/download/" className={link}>
            Download Keybumps
          </Link>
          .
        </li>
      </ul>
    </PageShell>
  )
}
