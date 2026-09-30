import type { Metadata } from 'next'
import Link from 'next/link'
import { PageShell } from '@/components/page-shell'

export const metadata: Metadata = {
  title: { absolute: 'Thanks for buying Keybumps' },
  alternates: { canonical: '/thanks/' },
  robots: { index: false, follow: false },
  // The URL carries Polar's customer-session token; never send it on as a Referer.
  referrer: 'no-referrer'
}

// Polar appends checkout and customer-session parameters to this URL. The page never reads
// or echoes them, and the (no-analytics) layout's StripQuery removes them from the address bar and
// history once the page renders.
export default function ThanksPage() {
  return (
    <PageShell title="Thanks for buying Keybumps">
      <p>
        Your license key is in the receipt email from Polar, sent to the address you used at
        checkout. It usually arrives within a minute.
      </p>
      <h2>Activate Keybumps</h2>
      <ol>
        <li>
          <Link href="/download/">Download Keybumps</Link> if you haven’t already.
        </li>
        <li>Open Keybumps and go to Settings → License.</li>
        <li>Paste your license key and choose Activate.</li>
      </ol>
      <p>
        No email? Check your spam folder, or{' '}
        <Link href="/license/">find your key in the customer portal</Link>.
      </p>
    </PageShell>
  )
}
