/**
 * Sends server-side events to Google Analytics 4 through the Measurement Protocol (#363). Only the
 * Polar webhook (`lib/polar-webhook.ts`) uses it, to record purchases and refunds with Polar's real
 * amounts; the browser's analytics stay in Google Tag Manager (`components/analytics.tsx`).
 * `analytics-scope.test.ts` keeps this module out of every page.
 *
 * Off the live site, events go to the validation endpoint, which checks them and records nothing,
 * so staging can be tested end to end with Polar's sandbox.
 */

export interface Ga4Config {
  measurementId: string
  /** A Measurement Protocol API secret (GA4 › Admin › Data streams), set as a Worker secret. */
  apiSecret: string
  /** Send to the validation endpoint, which records nothing. */
  validateOnly: boolean
}

export interface Ga4Event {
  name: 'purchase' | 'refund'
  params: Record<string, unknown>
}

export interface Ga4Payload {
  client_id: string
  events: Ga4Event[]
}

export type Ga4Outcome = 'sent' | 'failed_network' | 'failed_status' | 'failed_validation'

const measurementIdPattern = /^G-[A-Z0-9]{4,20}$/
const requestTimeoutMs = 4000

/** The config from the Worker's environment, or null until both values are set. */
export function ga4ConfigFromEnv(env: Record<string, string | undefined>): Ga4Config | null {
  const measurementId = env.GA4_MEASUREMENT_ID
  const apiSecret = env.GA4_API_SECRET
  if (!measurementId || !measurementIdPattern.test(measurementId) || !apiSecret) return null
  return { measurementId, apiSecret, validateOnly: env.SITE_ENV !== 'production' }
}

/**
 * A client ID for a sale with none from the browser: a buyer who blocks analytics, or who bought
 * from another device. It's derived from the order, so a retried delivery gives the same ID, and
 * Google Analytics, which removes a repeated purchase only for the same client, removes it.
 */
export async function derivedClientId(seed: string): Promise<string> {
  const digest = new DataView(
    await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`keybumps:${seed}`))
  )
  return `${digest.getUint32(0)}.${digest.getUint32(4)}`
}

/** Sends one payload. The URL holds the API secret, so it must never be logged. */
export async function sendToGa4(
  config: Ga4Config,
  payload: Ga4Payload,
  fetchImpl: typeof fetch = fetch
): Promise<Ga4Outcome> {
  const path = config.validateOnly ? '/debug/mp/collect' : '/mp/collect'
  const url = new URL(path, 'https://www.google-analytics.com')
  url.searchParams.set('measurement_id', config.measurementId)
  url.searchParams.set('api_secret', config.apiSecret)
  let response: Response
  try {
    response = await fetchImpl(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(requestTimeoutMs)
    })
  } catch {
    return 'failed_network'
  }
  if (!response.ok) return 'failed_status'
  if (!config.validateOnly) return 'sent'
  const body = (await response.json().catch(() => null)) as {
    validationMessages?: unknown[]
  } | null
  return Array.isArray(body?.validationMessages) && body.validationMessages.length === 0
    ? 'sent'
    : 'failed_validation'
}
