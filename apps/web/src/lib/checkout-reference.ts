import { pricing } from './pricing'

/**
 * The checkout reference (#363): the visitor's anonymous Google Analytics IDs, carried through
 * Polar's checkout so the paid order's webhook can credit the sale to the visit that led to it
 * (`lib/polar-webhook.ts`). /buy/ reads them from the first-party cookies Google Analytics sets
 * and passes them to Polar as the checkout link's `reference_id`, which Polar keeps in the
 * checkout's metadata and copies to the order and its renewals. Google Analytics sets these
 * cookies only where the visitor allowed analytics (`lib/consent.ts`), so their presence is the
 * consent signal. Nothing else goes in: no name, email, or other personal data.
 */
export interface CheckoutReference {
  /** Google Analytics' client ID, from the `_ga` cookie: `1234567890.1700000000`. */
  gaClientId?: string
  /** Google Analytics' session ID, from the `_ga_<stream>` cookie: `1700000000`. */
  gaSessionId?: string
}

/** The order metadata key Polar stores a checkout link's `reference_id` under. */
export const referenceMetadataKey = 'reference_id'

const gaClientIdPattern = /^\d{1,20}\.\d{1,20}$/
const gaSessionIdPattern = /^\d{1,20}$/
const measurementIdPattern = /^G-[A-Z0-9]{4,20}$/

/** `_ga`'s value, `GA1.1.1234567890.1700000000`, gives the client ID `1234567890.1700000000`. */
export function gaClientIdFromCookie(value: string | undefined): string | undefined {
  return value?.match(/^GA\d+\.\d+\.(\d{1,20}\.\d{1,20})$/)?.[1]
}

/**
 * `_ga_<stream>`'s value gives the session ID, in either format Google Analytics writes:
 * `GS1.1.1700000000.3.1.1700000100.0.0.0` or `GS2.1.s1700000000$o3$g1$t1700000100$j0$l0$h0`.
 */
export function gaSessionIdFromCookie(value: string | undefined): string | undefined {
  if (!value) return undefined
  return (
    value.match(/^GS1\.\d+\.(\d{1,20})(?:\.|$)/)?.[1] ??
    value.match(/^GS2\.\d+\.s(\d{1,20})(?:\$|$)/)?.[1]
  )
}

/** The session cookie for a GA4 measurement ID: `G-ABC123` keeps its session in `_ga_ABC123`. */
export function gaSessionCookieName(measurementId: string | undefined): string | undefined {
  return measurementId && measurementIdPattern.test(measurementId)
    ? `_ga_${measurementId.slice(2)}`
    : undefined
}

/** One cookie's value from a `Cookie` request header. */
export function readCookie(header: string | null, name: string): string | undefined {
  if (!header) return undefined
  for (const part of header.split(';')) {
    const separator = part.indexOf('=')
    if (separator < 0 || part.slice(0, separator).trim() !== name) continue
    return part.slice(separator + 1).trim()
  }
  return undefined
}

/** The reference for a request's cookies, or an empty one when there are none to send. */
export function referenceFromCookies(
  cookieHeader: string | null,
  measurementId: string | undefined
): CheckoutReference {
  const gaClientId = gaClientIdFromCookie(readCookie(cookieHeader, '_ga'))
  if (!gaClientId) return {}
  const sessionCookie = gaSessionCookieName(measurementId)
  const gaSessionId = sessionCookie
    ? gaSessionIdFromCookie(readCookie(cookieHeader, sessionCookie))
    : undefined
  return gaSessionId ? { gaClientId, gaSessionId } : { gaClientId }
}

/** The reference as Polar keeps it: `ga=1234567890.1700000000&gs=1700000000`, or null when empty. */
export function encodeCheckoutReference(reference: CheckoutReference): string | null {
  const params = new URLSearchParams()
  if (reference.gaClientId) params.set('ga', reference.gaClientId)
  if (reference.gaSessionId) params.set('gs', reference.gaSessionId)
  const encoded = params.toString()
  return encoded || null
}

/**
 * A reference read back from an order's metadata. Anyone can open a checkout link with their own
 * `reference_id`, so each part must match the format /buy/ writes, or it's dropped.
 */
export function parseCheckoutReference(value: unknown): CheckoutReference {
  if (typeof value !== 'string' || value.length > 500) return {}
  const params = new URLSearchParams(value)
  const gaClientId = params.get('ga') ?? ''
  const gaSessionId = params.get('gs') ?? ''
  if (!gaClientIdPattern.test(gaClientId)) return {}
  return gaSessionIdPattern.test(gaSessionId) ? { gaClientId, gaSessionId } : { gaClientId }
}

/**
 * /buy/'s answer: a temporary redirect to Polar's checkout with the reference, never cached, since
 * it's built from this visitor's cookies. With no checkout configured, it goes to /pricing/.
 */
export function buyRedirect(
  cookieHeader: string | null,
  measurementId: string | undefined,
  checkoutUrl: string | null = pricing.checkoutUrl
): Response {
  let location = '/pricing/'
  if (checkoutUrl) {
    const url = new URL(checkoutUrl)
    const reference = encodeCheckoutReference(referenceFromCookies(cookieHeader, measurementId))
    if (reference) url.searchParams.set(referenceMetadataKey, reference)
    location = url.toString()
  }
  return new Response(null, {
    status: 302,
    headers: { Location: location, 'Cache-Control': 'private, no-store' }
  })
}
