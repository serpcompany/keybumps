import { PageShell } from '@/components/page-shell'
import { pageMetadata } from '@/lib/metadata'
import { pricing } from '@/lib/pricing'
import { SUPPORT_EMAIL } from '@/lib/site'

export const metadata = pageMetadata('/legal/refunds/')

export default function RefundsPage() {
  const email = <a href={`mailto:${SUPPORT_EMAIL}`}>{SUPPORT_EMAIL}</a>
  return (
    <PageShell title="Refund Policy" showUpdated>
      <h2>{pricing.guarantee}</h2>
      <p>
        If Keybumps isn’t right for you, ask for a refund within {pricing.refundDays} days of
        purchase and you’ll get your money back in full. No questions asked.
      </p>

      <h2>How to request a refund</h2>
      <p>
        Email {email} with the email address you used at checkout (or your order number). You can
        also request a refund directly from the Polar receipt or customer portal linked in your
        purchase email.
      </p>

      <h2>What happens next</h2>
      <ul>
        <li>
          Refunds are issued by Polar, our merchant of record, to the original payment method,
          usually within 5–10 business days depending on your bank.
        </li>
        <li>
          Once refunded, the license key is revoked and Keybumps stops working on any Mac it was
          activated on.
        </li>
      </ul>

      <h2>After {pricing.refundDays} days</h2>
      <p>
        Purchases older than {pricing.refundDays} days are generally not refundable, but if
        something has gone wrong — a duplicate charge, a purchase you didn’t make, or an issue we
        can’t fix — contact {email} and we’ll work it out. This policy doesn’t limit any rights you
        have under consumer law in your country.
      </p>
    </PageShell>
  )
}
