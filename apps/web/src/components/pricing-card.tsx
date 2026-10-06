import Link from 'next/link'
import { DownloadLink } from '@/components/download-link'
import { pricing, pricingIncludes } from '@/lib/pricing'

export function PricingCard() {
  return (
    <div className="price-card">
      <div className="price-head">
        <h3>Keybumps</h3>
        <span className="pill">{pricing.model.label}</span>
      </div>
      <p className="price">
        {pricing.price}
        {pricing.period}
        <span>
          {' '}
          {pricing.currency} · {pricing.macsLabel}
        </span>
      </p>
      <ul className="checks">
        {pricingIncludes.map(item => (
          <li key={item}>{item}</li>
        ))}
      </ul>
      {pricing.checkoutUrl ? (
        <a href={pricing.checkoutUrl} className="btn btn-lg price-cta">
          {pricing.cta} — {pricing.price}
          {pricing.period}
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
