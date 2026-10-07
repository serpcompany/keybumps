/**
 * Records partner sales in Dub (#337), so partners in the Keybumps partner program are credited
 * and paid. Only the Polar webhook (`lib/polar-webhook.ts`) uses it: a paid order whose checkout
 * reference has a Dub click becomes a Dub sale, and a full refund marks its commission refunded.
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
  | 'no_commission'
  | 'already_paid'
  | 'rejected'
  | 'failed_network'
  | 'failed_status'

const api = 'https://api.dub.co'
const requestTimeoutMs = 4000

/** The config from the Worker's environment: only on the live site, and only once the key is set. */
export function dubConfigFromEnv(env: Record<string, string | undefined>): DubConfig | null {
  const apiKey = env.DUB_API_KEY
  return env.SITE_ENV === 'production' && apiKey ? { apiKey } : null
}

/**
 * Tracks a sale. Dub keeps one sale per invoice ID, so a retried delivery records nothing new.
 * A sale whose click Dub doesn't know is accepted with no customer: `unattributed`.
 */
export async function trackDubSale(
  config: DubConfig,
  sale: DubSale,
  fetchImpl: typeof fetch = fetch
): Promise<DubOutcome> {
  const response = await request(config, fetchImpl, 'POST', '/track/sale', {
    ...sale,
    paymentProcessor: 'polar'
  })
  if (typeof response === 'string') return response
  const body = (await response.json().catch(() => null)) as { customer?: unknown } | null
  return body?.customer ? 'sent' : 'unattributed'
}

/**
 * Marks the commission for a fully refunded order refunded, so it leaves the partner's next
 * payout. A commission Dub has already paid can't change: that needs a clawback in Dub, by hand.
 */
export async function refundDubCommission(
  config: DubConfig,
  invoiceId: string,
  fetchImpl: typeof fetch = fetch
): Promise<DubOutcome> {
  const listed = await request(
    config,
    fetchImpl,
    'GET',
    `/commissions?${new URLSearchParams({ invoiceId })}`
  )
  if (typeof listed === 'string') return listed
  const commissions = (await listed.json().catch(() => null)) as
    | { id?: unknown; status?: unknown }[]
    | null
  const commission = Array.isArray(commissions) ? commissions[0] : undefined
  if (!commission || typeof commission.id !== 'string') return 'no_commission'
  if (commission.status === 'refunded') return 'refunded'
  if (commission.status === 'paid') return 'already_paid'
  const updated = await request(
    config,
    fetchImpl,
    'PATCH',
    `/commissions/${encodeURIComponent(commission.id)}`,
    { status: 'refunded' }
  )
  return typeof updated === 'string' ? updated : 'refunded'
}

/**
 * One API call. A network error, a 429, or a 5xx is worth retrying (`failed_*`); any other 4xx
 * won't change on a retry, so it's `rejected`.
 */
async function request(
  config: DubConfig,
  fetchImpl: typeof fetch,
  method: string,
  path: string,
  body?: unknown
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
      signal: AbortSignal.timeout(requestTimeoutMs)
    })
  } catch {
    return 'failed_network'
  }
  if (response.ok) return response
  return response.status === 429 || response.status >= 500 ? 'failed_status' : 'rejected'
}
