import { ga4ConfigFromEnv } from '@/lib/ga4-measurement-protocol'
import { handlePolarWebhook } from '@/lib/polar-webhook'

// Polar's webhook (#363): paid orders and refunds become GA4 purchases and refunds with Polar's
// real amounts (lib/polar-webhook.ts). Register it in Polar exactly as
// https://keybumps.app/api/webhooks/polar/ (Polar treats a redirect as a failed delivery).
export const dynamic = 'force-dynamic'

export function POST(request: Request) {
  return handlePolarWebhook(request, {
    secret: process.env.POLAR_WEBHOOK_SECRET,
    ga4: ga4ConfigFromEnv(process.env)
  })
}
