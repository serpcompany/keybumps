import Link from 'next/link'
import { DownloadLink } from '@/components/download-link'
import { CHECKOUT_URL, PRICE } from '@/lib/site'

const INCLUDED = [
  'Every plugin, including the ones future updates add',
  'License for 1 Mac — move it to a new Mac any time',
  'All future updates included',
  'No account and no cloud sync',
  '30-day money-back guarantee'
]

export function PricingCard() {
  return (
    <div className="price-card">
      <div className="price-head">
        <h3>Keybumps</h3>
        <span className="pill">One-time purchase</span>
      </div>
      <p className="price">
        {PRICE}
        <span> USD · 1 Mac</span>
      </p>
      <ul className="checks">
        {INCLUDED.map(item => (
          <li key={item}>{item}</li>
        ))}
      </ul>
      {CHECKOUT_URL ? (
        <a href={CHECKOUT_URL} className="btn btn-lg price-cta">
          Buy Keybumps — {PRICE}
        </a>
      ) : (
        <DownloadLink className="btn btn-lg price-cta">Download Keybumps</DownloadLink>
      )}
      <p className="fine">
        Taxes calculated at checkout. Payments are processed by Polar, our merchant of record. See
        the <Link href="/legal/refunds/">refund policy</Link>.
      </p>
    </div>
  )
}
