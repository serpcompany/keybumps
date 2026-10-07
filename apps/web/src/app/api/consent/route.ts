import { getCloudflareContext } from '@opennextjs/cloudflare'
import { requiresConsent } from '@/lib/consent'

// Whether this visitor chooses cookies first, from the country Cloudflare gives the request
// (`lib/consent.ts`). Only that answer leaves; the country itself isn't returned or logged.
export const dynamic = 'force-dynamic'

export async function GET(request: Request) {
  return Response.json(
    { required: requiresConsent(visitorCountry(request)) },
    { headers: { 'Cache-Control': 'private, no-store' } }
  )
}

/** The Worker's `cf.country`, or Cloudflare's `CF-IPCountry` header where there's no context. */
function visitorCountry(request: Request): string | null {
  try {
    const country = getCloudflareContext().cf?.country
    if (typeof country === 'string') return country
  } catch {
    // Outside the Worker, such as in tests and `next dev`.
  }
  return request.headers.get('cf-ipcountry')
}
