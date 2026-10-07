import { getCloudflareContext } from '@opennextjs/cloudflare'

/**
 * A request's two-letter country, from Cloudflare: the Worker's `cf.country`, or the
 * `CF-IPCountry` header where there's no Worker context. Server only; `/api/consent/` and /buy/
 * use it to apply `requiresConsent` (`lib/consent.ts`).
 */
export function requestCountry(request: Request): string | null {
  try {
    const country = getCloudflareContext().cf?.country
    if (typeof country === 'string') return country
  } catch {
    // Outside the Worker, such as in tests and `next dev`.
  }
  return request.headers.get('cf-ipcountry')
}
