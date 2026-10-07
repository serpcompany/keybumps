import {
  type CheckoutReference,
  parseCheckoutReference,
  referenceMetadataKey
} from './checkout-reference'
import { requiresConsent } from './consent'
import {
  type DubConfig,
  type DubOutcome,
  type DubSale,
  refundDubCommission,
  trackDubSale
} from './dub-conversions'
import {
  derivedClientId,
  type Ga4Config,
  type Ga4Outcome,
  type Ga4Payload,
  sendToGa4
} from './ga4-measurement-protocol'

/**
 * Polar's webhook (#363): `POST /api/webhooks/polar/`. A paid order becomes a GA4 `purchase` with
 * Polar's order ID, real amount after discounts, and currency, and a full refund becomes a GA4
 * `refund`. It replaces GTM's purchase tag on /thanks/, which had no order ID or real amount and
 * missed buyers who never reached that page. An order a Dub partner link brought also becomes a
 * Dub sale, and its full refund refunds the partner's commission (#337, `lib/dub-conversions.ts`).
 *
 * There is no database, so a retried delivery is handled downstream: Google Analytics removes a
 * repeated purchase with the same transaction ID and client (`derivedClientId` keeps the client
 * stable), and Dub keeps one sale per invoice ID. A delivery succeeds (2xx) unless a send failed,
 * so Polar retries only then.
 *
 * Logs hold only the event type and outcomes, never order, customer, or reference data.
 */

/** Polar's Standard Webhooks headers allow this much clock difference, in seconds. */
const timestampToleranceSeconds = 5 * 60

export type SignatureError = 'missing_headers' | 'stale_timestamp' | 'bad_signature'

/**
 * Checks Polar's signature (Standard Webhooks: HMAC-SHA256 of `id.timestamp.body`). A secret made
 * on or after 8 September 2026 is a Standard Webhooks secret, whose key is the base64 after
 * `whsec_`; an older one is keyed by the UTF-8 bytes of the whole string. Both are tried.
 */
export async function verifyPolarSignature(
  body: string,
  headers: Headers,
  secret: string,
  now = Date.now()
): Promise<SignatureError | null> {
  const id = headers.get('webhook-id')
  const timestamp = headers.get('webhook-timestamp')
  const signatures = headers.get('webhook-signature')
  if (!id || !timestamp || !signatures || !/^\d{1,12}$/.test(timestamp)) return 'missing_headers'
  if (Math.abs(now / 1000 - Number(timestamp)) > timestampToleranceSeconds) return 'stale_timestamp'

  const signed = new TextEncoder().encode(`${id}.${timestamp}.${body}`)
  const candidates = signatures
    .split(' ')
    .filter(part => part.startsWith('v1,'))
    .map(part => base64ToBytes(part.slice(3)))
    .filter(bytes => bytes !== null)
  for (const keyBytes of signingKeys(secret)) {
    const key = await crypto.subtle.importKey(
      'raw',
      keyBytes,
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['verify']
    )
    for (const candidate of candidates) {
      if (await crypto.subtle.verify('HMAC', key, candidate, signed)) return null
    }
  }
  return 'bad_signature'
}

function signingKeys(secret: string): Uint8Array<ArrayBuffer>[] {
  const keys = [new TextEncoder().encode(secret)]
  const standard = base64ToBytes(secret.startsWith('whsec_') ? secret.slice(6) : secret)
  if (standard?.length) keys.unshift(standard)
  return keys
}

function base64ToBytes(value: string): Uint8Array<ArrayBuffer> | null {
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(value)) return null
  try {
    return Uint8Array.from(atob(value), char => char.charCodeAt(0))
  } catch {
    return null
  }
}

/** The parts of a Polar order this webhook reads. */
export interface PolarOrder {
  id: string
  status: string
  billingReason: string
  /** In cents: after discounts, before tax. */
  netAmount: number
  taxAmount: number
  refundedAmount: number
  currency: string
  /** Polar's customer ID: Dub's customer ID for the partner's sales. */
  customerId: string | null
  /** The billing address's two-letter country, if Polar has one. */
  country: string | null
  productId: string | null
  productName: string | null
  discountCode: string | null
  reference: CheckoutReference
}

/** An order from a webhook's `data`, or null when it isn't one. */
export function orderFromPayload(data: unknown): PolarOrder | null {
  if (!isRecord(data)) return null
  const { id, status, billing_reason, net_amount, tax_amount, refunded_amount, currency } = data
  if (
    typeof id !== 'string' ||
    typeof status !== 'string' ||
    typeof billing_reason !== 'string' ||
    !isCents(net_amount) ||
    !isCents(tax_amount) ||
    !isCents(refunded_amount) ||
    typeof currency !== 'string' ||
    !/^[a-z]{3}$/i.test(currency)
  ) {
    return null
  }
  const address = isRecord(data.billing_address) ? data.billing_address : null
  const product = isRecord(data.product) ? data.product : null
  const discount = isRecord(data.discount) ? data.discount : null
  const metadata = isRecord(data.metadata) ? data.metadata : {}
  return {
    id,
    status,
    billingReason: billing_reason,
    netAmount: net_amount,
    taxAmount: tax_amount,
    refundedAmount: refunded_amount,
    currency: currency.toUpperCase(),
    customerId: typeof data.customer_id === 'string' ? data.customer_id : null,
    country: typeof address?.country === 'string' ? address.country : null,
    productId: typeof data.product_id === 'string' ? data.product_id : null,
    productName: typeof product?.name === 'string' ? product.name : null,
    discountCode: typeof discount?.code === 'string' ? discount.code : null,
    reference: parseCheckoutReference(metadata[referenceMetadataKey])
  }
}

/** The webhook events this route acts on. */
export const handledEvents = ['order.paid', 'order.refunded'] as const
export type HandledEvent = (typeof handledEvents)[number]

export type Ga4Skip = 'zero_amount' | 'not_paid' | 'partial_refund' | 'no_consent'

/**
 * The GA4 event for an order, or why there's none. A buyer billed in a country that chooses
 * cookies first (`lib/consent.ts`) is counted only with a client ID from /buy/, which gives one
 * there only when the visitor allowed analytics. Without one, a buyer billed elsewhere is counted
 * under a derived client ID.
 */
export async function ga4PayloadForOrder(
  event: HandledEvent,
  order: PolarOrder
): Promise<Ga4Payload | Ga4Skip> {
  if (event === 'order.paid') {
    if (order.status !== 'paid') return 'not_paid'
    if (order.netAmount <= 0) return 'zero_amount'
  } else if (order.status !== 'refunded') {
    // A partial refund's own amount isn't known without the earlier ones, so it isn't sent, and
    // GA4's revenue keeps it. The full-refund policy makes these rare.
    return 'partial_refund'
  }
  const { gaClientId, gaSessionId } = order.reference
  if (!gaClientId && requiresConsent(order.country)) return 'no_consent'

  const client_id = gaClientId ?? (await derivedClientId(order.id))
  if (event === 'order.refunded') {
    return {
      client_id,
      events: [
        {
          name: 'refund',
          params: {
            transaction_id: order.id,
            value: toUnits(order.refundedAmount),
            currency: order.currency
          }
        }
      ]
    }
  }
  const value = toUnits(order.netAmount)
  // A renewal happens long after the visit, so it isn't credited to that session.
  const firstPayment =
    order.billingReason === 'purchase' || order.billingReason === 'subscription_create'
  return {
    client_id,
    events: [
      {
        name: 'purchase',
        params: {
          transaction_id: order.id,
          value,
          currency: order.currency,
          tax: toUnits(order.taxAmount),
          ...(order.discountCode ? { coupon: order.discountCode } : {}),
          ...(gaSessionId && firstPayment ? { session_id: gaSessionId } : {}),
          items: [
            {
              item_id: order.productId ?? 'keybumps',
              item_name: order.productName ?? 'Keybumps',
              price: value,
              quantity: 1
            }
          ]
        }
      }
    ]
  }
}

export type DubSkip = 'no_click' | 'zero_amount' | 'not_paid' | 'no_customer'

/** Dub's names for the payment, so a partner's dashboard tells a purchase from a renewal. */
const dubEventNames: Record<string, string> = {
  purchase: 'Purchase',
  subscription_create: 'Subscription created'
}

/**
 * The Dub sale for a paid order a partner link brought, or why there's none. The click rides in
 * the checkout reference, which Polar copies to renewals too, so each renewal is credited as well.
 */
export function dubSaleForOrder(order: PolarOrder): DubSale | DubSkip {
  if (order.status !== 'paid') return 'not_paid'
  if (order.netAmount <= 0) return 'zero_amount'
  const clickId = order.reference.dubClickId
  if (!clickId) return 'no_click'
  if (!order.customerId) return 'no_customer'
  return {
    clickId,
    // Prefixed: other SERP products in the same Dub workspace may sell through the same Polar
    // organization, and one Dub customer would credit every product's sales to one partner.
    customerExternalId: `keybumps_${order.customerId}`,
    amount: order.netAmount,
    currency: order.currency.toLowerCase(),
    invoiceId: order.id,
    eventName: dubEventNames[order.billingReason] ?? 'Invoice paid'
  }
}

async function sendToDub(
  config: DubConfig,
  event: HandledEvent,
  order: PolarOrder,
  fetchImpl: typeof fetch
): Promise<DubOutcome | DubSkip> {
  if (event === 'order.refunded') {
    if (!order.reference.dubClickId) return 'no_click'
    // Unlike GA4's, Dub's commission takes the sale's new total, so a partial refund is exact.
    const remaining = order.status === 'refunded' ? 0 : order.netAmount - order.refundedAmount
    return refundDubCommission(config, order.id, remaining, order.currency.toLowerCase(), fetchImpl)
  }
  const sale = dubSaleForOrder(order)
  return typeof sale === 'string' ? sale : trackDubSale(config, sale, fetchImpl)
}

export interface PolarWebhookEnv {
  /** Polar's webhook secret (`POLAR_WEBHOOK_SECRET`). Without it, every delivery gets a 503. */
  secret: string | undefined
  /** Null until GA4's measurement ID and API secret are both set. */
  ga4: Ga4Config | null
  /** Null off the live site, and until Dub's API key is set. */
  dub: DubConfig | null
  fetch?: typeof fetch
  now?: number
}

type Ga4Result = Ga4Outcome | Ga4Skip | 'not_configured' | 'deferred'
type DubResult = DubOutcome | DubSkip | 'not_configured'

/** Handles one delivery: verify, act on a handled event, and log what happened. */
export async function handlePolarWebhook(
  request: Request,
  env: PolarWebhookEnv
): Promise<Response> {
  if (!env.secret) return respond(503, { outcome: 'not_configured' })
  const body = await request.text()
  const error = await verifyPolarSignature(body, request.headers, env.secret, env.now)
  if (error) return respond(401, { outcome: error })

  let payload: unknown
  try {
    payload = JSON.parse(body)
  } catch {
    return respond(400, { outcome: 'bad_json' })
  }
  const type = isRecord(payload) && typeof payload.type === 'string' ? payload.type : ''
  if (!(handledEvents as readonly string[]).includes(type)) {
    return respond(202, { outcome: 'ignored' })
  }
  const event = type as HandledEvent
  const order = orderFromPayload(isRecord(payload) ? payload.data : null)
  if (!order) return respond(202, { type: event, outcome: 'unexpected_payload' })

  const fetchImpl = env.fetch ?? fetch
  const ga4Config = env.ga4
  const dubConfig = env.dub
  const toGa4 = async (): Promise<Ga4Result> => {
    if (!ga4Config) return 'not_configured'
    const ga4Payload = await ga4PayloadForOrder(event, order)
    return typeof ga4Payload === 'string' ? ga4Payload : sendToGa4(ga4Config, ga4Payload, fetchImpl)
  }
  const toDub = (): Promise<DubResult> =>
    dubConfig ? sendToDub(dubConfig, event, order, fetchImpl) : Promise.resolve('not_configured')
  let ga4: Ga4Result
  let dub: DubResult
  if (event === 'order.refunded') {
    // GA4 drops a repeated purchase but not a repeated refund, so a refund goes to GA4 only once
    // Dub, the side a retry is for, has taken it.
    dub = await toDub()
    ga4 = dub.startsWith('failed_') ? 'deferred' : await toGa4()
  } else {
    // A retry repeats both, and both drop the repeat: GA4 by transaction and client, Dub by invoice.
    ;[ga4, dub] = await Promise.all([toGa4(), toDub()])
  }
  const failed = ga4.startsWith('failed_') || dub.startsWith('failed_')
  return respond(failed ? 502 : 202, {
    type: event,
    outcome: failed ? 'failed' : 'handled',
    ga4,
    dub
  })
}

/** Responds and logs one structural line: no IDs, amounts, or customer data. */
function respond(status: number, log: Record<string, string>): Response {
  console.log(JSON.stringify({ event: 'polar_webhook', status, ...log }))
  return new Response(null, { status })
}

function toUnits(cents: number): number {
  return Math.round(cents) / 100
}

function isCents(value: unknown): value is number {
  return typeof value === 'number' && Number.isInteger(value) && value >= 0
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
