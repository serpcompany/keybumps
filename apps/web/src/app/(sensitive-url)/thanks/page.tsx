import type { Metadata } from 'next'
import Link from 'next/link'
import { DownloadLink } from '@/components/download-link'
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
    <main className="section first">
      <div className="container narrow text-center">
        <h1 className="text-[clamp(2rem,5vw,2.8rem)]">Thanks for buying Keybumps</h1>
        <p className="section-lede">
          Check your email for your license key from Polar. It usually arrives within a minute.
        </p>
        <DownloadLink className="btn btn-lg px-8 py-4 text-lg">Download Keybumps</DownloadLink>
        <p className="fine mt-10">
          No email? Check your spam folder, or{' '}
          <Link href="/license/" prefetch={false}>
            find your key in the customer portal
          </Link>
          .
        </p>
      </div>
    </main>
  )
}
