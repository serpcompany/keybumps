import { requiresConsent } from '@/lib/consent'
import { requestCountry } from '@/lib/request-country'

// Whether this visitor chooses cookies first, from the country Cloudflare gives the request
// (`lib/consent.ts`). Only that answer leaves; the country itself isn't returned or logged.
export const dynamic = 'force-dynamic'

export async function GET(request: Request) {
  return Response.json(
    { required: requiresConsent(requestCountry(request)) },
    { headers: { 'Cache-Control': 'private, no-store' } }
  )
}
