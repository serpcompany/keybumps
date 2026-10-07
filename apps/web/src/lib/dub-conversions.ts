/**
 * Records partner sales in Dub (#337), so partners in the Keybumps partner program are credited
 * and paid. Only the Polar webhook (`lib/polar-webhook.ts`) uses it: a paid order whose checkout
 * reference has a Dub click becomes a Dub sale, and a refund updates its commission.
 * Dub gets the click, Polar's customer ID, the order ID, the amount, and the currency; never the
 * buyer's name or email, so Dub shows partners a made-up name.
 *
 * Dub has no test mode, so only the live site sends; staging's sandbox orders never reach it.
 */

export interface DubConfig {
  /** A Dub API key with conversion and commission access, set as a Worker secret. */
  apiKey: string
}

export interface DubSale {
  clickId: string
  customerExternalId: string
  /** In cents. */
  amount: number
  /** Lowercase ISO 4217, as Dub's examples write it. */
  currency: string
  invoiceId: string
  eventName: string
}

export type DubOutcome =
  | 'sent'
  | 'unattributed'
  | 'refunded'
  | 'adjusted'
  | 'unchanged'
  | 'no_commission'
  | 'already_paid'
  | 'closed'
  | 'rejected'
  | 'failed_auth'
  | 'failed_network'
  | 'failed_status'

const api = 'https://api.dub.co'
/** A sale runs alongside GA4's call, so it can wait longer than Polar's 10 s allows for a refund. */
const saleTimeoutMs = 6000
/** A refund makes two calls before GA4's; all three must finish inside Polar's 10-second timeout. */
const refundCallTimeoutMs = 2500

/** The config from the Worker's environment: only on the live site, and only once the key is set. */
export function dubConfigFromEnv(env: Record<string, string | undefined>): DubConfig | null {
  const apiKey = env.DUB_API_KEY
  return env.SITE_ENV === 'production' && apiKey ? { apiKey } : null
}

/**
 * Tracks a sale. Dub ignores a repeat of an invoice ID for 7 days, so Polar's retries record
 * nothing new; a manual redelivery after that adds to Dub's sale stats, though never a second
 * commission. A click Dub doesn't know (expired, forged, or its link deleted or disabled) is a 404:
 * `unattributed`, never worth retrying.
 */
export async function trackDubSale(
  config: DubConfig,
  sale: DubSale,
  fetchImpl: typeof fetch = fetch
): Promise<DubOutcome> {
  const response = await request(
    config,
    fetchImpl,
    'POST',
    '/track/sale',
    { ...sale, paymentProcessor: 'polar' },
    { notFound: 'unattributed', timeoutMs: saleTimeoutMs }
  )
  return typeof response === 'string' ? response : 'sent'
}

/**
 * Updates the partner's commission for a refunded order. A full refund (`remainingCents` 0) marks
 * it refunded, so it leaves the next payout; a partial one sets the sale to what's left, which is
 * safe to send again. Dub takes the change while the commission is pending, on hold, or in a payout
 * not yet sent (`processed`). One it has paid, or whose payout is already being sent, needs a
 * clawback in Dub, by hand (`already_paid`); a duplicate, fraudulent, or canceled one is left
 * alone (`closed`).
 */
export async function refundDubCommission(
  config: DubConfig,
  invoiceId: string,
  remainingCents: number,
  currency: string,
  fetchImpl: typeof fetch = fetch
): Promise<DubOutcome> {
  const listed = await request(
    config,
    fetchImpl,
    'GET',
    `/commissions?${new URLSearchParams({ invoiceId })}`,
    undefined,
    { timeoutMs: refundCallTimeoutMs }
  )
  if (typeof listed === 'string') return listed
  // An unreadable list (cut off by the timeout, say) is worth retrying, not "no commission".
  const commissions = (await listed.json().catch(() => null)) as unknown
  if (!Array.isArray(commissions)) return 'failed_status'
  const commission = commissions[0] as
    | { id?: unknown; status?: unknown; amount?: unknown }
    | undefined
  if (!commission || typeof commission.id !== 'string') return 'no_commission'
  if (commission.status === 'refunded') return 'refunded'
  if (commission.status === 'paid') return 'already_paid'
  // Only these can change; anything else (duplicate, fraud, canceled, or a new status) is left.
  if (!['pending', 'hold', 'processed'].includes(String(commission.status))) return 'closed'
  const full = remainingCents <= 0
  // A retried older partial refund must not raise a sale a later refund already lowered.
  if (!full && typeof commission.amount === 'number' && remainingCents >= commission.amount) {
    return 'unchanged'
  }
  const updated = await request(
    config,
    fetchImpl,
    'PATCH',
    `/commissions/${encodeURIComponent(commission.id)}`,
    full ? { status: 'refunded' } : { saleAmount: remainingCents, currency },
    { notFound: 'no_commission', timeoutMs: refundCallTimeoutMs }
  )
  // Dub refuses (400) a commission whose payout is already being sent: that one is paid in effect.
  if (updated === 'rejected' && commission.status === 'processed') return 'already_paid'
  if (typeof updated === 'string') return updated
  return full ? 'refunded' : 'adjusted'
}

/**
 * One API call. A network error, a 429, or a 5xx is worth retrying (`failed_*`), and so is a 401
 * or 403 (`failed_auth`: a revoked key or a missing permission), so the delivery shows as failed
 * in Polar and can be redelivered once the key is fixed. Any other 4xx won't change on a retry:
 * `rejected`, or `notFound` for a 404 where the caller names one.
 */
async function request(
  config: DubConfig,
  fetchImpl: typeof fetch,
  method: string,
  path: string,
  body: unknown,
  { notFound = 'rejected', timeoutMs }: { notFound?: DubOutcome; timeoutMs: number }
): Promise<Response | DubOutcome> {
  let response: Response
  try {
    response = await fetchImpl(`${api}${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${config.apiKey}`,
        ...(body ? { 'Content-Type': 'application/json' } : {})
      },
      ...(body ? { body: JSON.stringify(body) } : {}),
      signal: AbortSignal.timeout(timeoutMs)
    })
  } catch {
    return 'failed_network'
  }
  if (response.ok) return response
  if (response.status === 401 || response.status === 403) return 'failed_auth'
  if (response.status === 429 || response.status >= 500) return 'failed_status'
  return response.status === 404 ? notFound : 'rejected'
}
