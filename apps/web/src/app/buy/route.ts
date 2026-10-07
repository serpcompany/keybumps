import { buyRedirect } from '@/lib/checkout-reference'

// Buy buttons link here, not straight to Polar (#363). Each request gets a temporary redirect to
// Polar's checkout carrying the visitor's anonymous Google Analytics IDs, so the paid order can be
// credited to the visit that led to it (lib/checkout-reference.ts). Always run on request: the
// redirect is built from this visitor's cookies.
export const dynamic = 'force-dynamic'

export function GET(request: Request) {
  return buyRedirect(request.headers.get('cookie'), process.env.GA4_MEASUREMENT_ID)
}
