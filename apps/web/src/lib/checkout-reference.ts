import { consentCookieName, requiresConsent, storedConsent } from './consent'
import { pricing } from './pricing'

/**
 * The checkout reference (#363, #337): the visitor's anonymous Google Analytics IDs and Dub
 * partner click ID, carried through Polar's checkout so the paid order's webhook can credit the
 * sale to the visit and the partner that led to it (`lib/polar-webhook.ts`). /buy/ reads them from
 * the first-party cookies Google Analytics and Dub's script set and passes them to Polar as the
 * checkout link's `reference_id`, which Polar keeps in the checkout's metadata and copies to the
 * order and its renewals. Nothing else goes in: no name, email, or other personal data.
 *
 * A visitor from a country that chooses cookies first (`lib/consent.ts`) gets a reference only
 * with the consent cookie saying `granted`. A `_ga` cookie alone isn't consent: it can predate the
 * banner, and declining doesn't delete it. So the reference itself means the IDs may be used.
 */
export interface CheckoutReference {
  /** Google Analytics' client ID, from the `_ga` cookie: `1234567890.1700000000`. */
  gaClientId?: string
  /** Google Analytics' session ID, from the `_ga_<stream>` cookie: `1700000000`. */
  gaSessionId?: string
  /** The Dub partner link click that brought the visitor, from the `dub_id` cookie. */
  dubClickId?: string
}

/** The order metadata key Polar stores a checkout link's `reference_id` under. */
export const referenceMetadataKey = 'reference_id'

const gaClientIdPattern = /^\d{1,20}\.\d{1,20}$/
const gaSessionIdPattern = /^\d{1,20}$/
const dubClickIdPattern = /^[A-Za-z0-9_-]{1,64}$/
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
  const sessionCookie = gaSessionCookieName(measurementId)
  const gaSessionId =
    gaClientId && sessionCookie
      ? gaSessionIdFromCookie(readCookie(cookieHeader, sessionCookie))
      : undefined
  const dubClickId = readCookie(cookieHeader, 'dub_id')
  return compact({
    gaClientId,
    gaSessionId,
    dubClickId: dubClickId && dubClickIdPattern.test(dubClickId) ? dubClickId : undefined
  })
}

/**
 * The reference as Polar keeps it, `ga=1234567890.1700000000&gs=1700000000&dub=…`, or null when
 * empty.
 */
export function encodeCheckoutReference(reference: CheckoutReference): string | null {
  const params = new URLSearchParams()
  if (reference.gaClientId) params.set('ga', reference.gaClientId)
  if (reference.gaSessionId) params.set('gs', reference.gaSessionId)
  if (reference.dubClickId) params.set('dub', reference.dubClickId)
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
  const valid = (key: string, pattern: RegExp) => {
    const part = params.get(key)
    return part && pattern.test(part) ? part : undefined
  }
  const gaClientId = valid('ga', gaClientIdPattern)
  return compact({
    gaClientId,
    // A session means nothing without its client.
    gaSessionId: gaClientId ? valid('gs', gaSessionIdPattern) : undefined,
    dubClickId: valid('dub', dubClickIdPattern)
  })
}

/** The reference without its empty parts. */
function compact(reference: CheckoutReference): CheckoutReference {
  return Object.fromEntries(
    Object.entries(reference).filter(([, value]) => value !== undefined)
  ) as CheckoutReference
}

/** Whether this visitor's IDs may go with a purchase: no choice needed, or analytics granted. */
export function referenceAllowed(cookieHeader: string | null, country: string | null): boolean {
  return (
    !requiresConsent(country) ||
    storedConsent(readCookie(cookieHeader, consentCookieName)) === 'granted'
  )
}

/**
 * /buy/'s answer: a temporary redirect to Polar's checkout with the reference, never cached, since
 * it's built from this visitor's cookies. With no checkout configured, it goes to /pricing/.
 * `country` is the request's, from Cloudflare (`lib/request-country.ts`).
 */
export function buyRedirect(
  cookieHeader: string | null,
  measurementId: string | undefined,
  country: string | null,
  checkoutUrl: string | null = pricing.checkoutUrl
): Response {
  let location = '/pricing/'
  if (checkoutUrl) {
    const url = new URL(checkoutUrl)
    const reference = referenceAllowed(cookieHeader, country)
      ? encodeCheckoutReference(referenceFromCookies(cookieHeader, measurementId))
      : null
    if (reference) url.searchParams.set(referenceMetadataKey, reference)
    location = url.toString()
  }
  return new Response(null, {
    status: 302,
    headers: { Location: location, 'Cache-Control': 'private, no-store' }
  })
}
