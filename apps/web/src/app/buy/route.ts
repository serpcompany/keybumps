import { buyRedirect } from '@/lib/checkout-reference'
import { requestCountry } from '@/lib/request-country'

// Buy buttons link here, not straight to Polar (#363). Each request gets a temporary redirect to
// Polar's checkout carrying the visitor's anonymous Google Analytics IDs, where their consent
// allows, so the paid order can be credited to the visit that led to it
// (lib/checkout-reference.ts). Always run on request: the redirect is built from this visitor's
// cookies and country.
export const dynamic = 'force-dynamic'

export function GET(request: Request) {
  return buyRedirect(
    request.headers.get('cookie'),
    process.env.GA4_MEASUREMENT_ID,
    requestCountry(request)
  )
}
