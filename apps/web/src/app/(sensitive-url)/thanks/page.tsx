import type { Metadata } from 'next'
import Link from 'next/link'
import { PageShell } from '@/components/page-shell'
import { redirectWithoutQuery } from '@/lib/sensitive-url'

export const metadata: Metadata = {
  title: { absolute: 'Thanks for buying Keybumps' },
  alternates: { canonical: '/thanks/' },
  robots: { index: false, follow: false },
  // The URL carries Polar's customer-session token; never send it on as a Referer.
  referrer: 'no-referrer'
}

// Polar appends checkout and customer-session parameters to this URL. The page redirects to
// /thanks/ without them before rendering anything, so no page, router state, or analytics ever
// holds them (see src/lib/sensitive-url.ts).
export default async function ThanksPage({ searchParams }: PageProps<'/thanks'>) {
  await redirectWithoutQuery('/thanks/', searchParams)
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
        <Link href="/license/" prefetch={false}>
          find your key in the customer portal
        </Link>
        .
      </p>
    </PageShell>
  )
}
