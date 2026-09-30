import Link from 'next/link'
import { PricingCard } from '@/components/pricing-card'
import { pageMetadata } from '@/lib/metadata'
import { PRICE, SUPPORT_EMAIL } from '@/lib/site'

export const metadata = pageMetadata('/pricing/')

const QUESTIONS = [
  {
    q: 'Is this a subscription?',
    a: `No. You pay ${PRICE} once and the license is yours to keep. It includes all future updates.`
  },
  {
    q: 'How do I activate it?',
    a: 'After checkout you receive a license key by email. Paste it into Keybumps → Settings → License. Activation needs an internet connection once; after that Keybumps checks in occasionally to keep the license current.'
  },
  {
    q: 'Can I move it to a new Mac?',
    a: 'Yes. Deactivate it in Settings on the old Mac, then activate on the new one. If the old Mac is lost or wiped, deactivate it from the Polar customer portal.'
  },
  {
    q: 'I lost my license key.',
    a: 'It’s in your Polar receipt email, and in the Polar customer portal. See keybumps.app/license/.'
  },
  {
    q: 'Who handles payment?',
    a: 'Polar (polar.sh) is our merchant of record. They process the payment, handle sales tax and VAT, and issue your receipt.'
  }
]

export default function PricingPage() {
  return (
    <main>
      <section className="section first">
        <div className="container">
          <h2>Simple pricing</h2>
          <p className="section-lede">One app, one price. No subscription, no account.</p>
          <PricingCard />
        </div>
      </section>
      <section className="section">
        <div className="container narrow">
          <h2>License questions</h2>
          <div className="faq">
            {QUESTIONS.map(item => (
              <details key={item.q}>
                <summary>{item.q}</summary>
                <p>{item.a}</p>
              </details>
            ))}
          </div>
          <p className="section-lede">
            Something else? Email <a href={`mailto:${SUPPORT_EMAIL}`}>{SUPPORT_EMAIL}</a> or read
            the <Link href="/legal/terms/">terms</Link>.
          </p>
        </div>
      </section>
    </main>
  )
}
