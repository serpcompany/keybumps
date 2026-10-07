import { GoogleTagManager } from '@next/third-parties/google'
import Script from 'next/script'
import { isProductionSite } from '@/lib/site'

/**
 * Production-only analytics, rendered only by the two root layouts, src/app/(analytics)/ and
 * src/app/(sensitive-url)/. The (sensitive-url) layout serves pages whose URLs carry checkout,
 * session, or license data (/thanks/, /license/) and removes the query string in `<head>`, so GTM,
 * which this loads after hydration, never sees it. Never render this anywhere else, and never on
 * the global 404. Each tool stays off until its ID is set at build time.
 *
 * The owner chose Google Tag Manager only, so NEXT_PUBLIC_CF_BEACON_TOKEN stays unset.
 */
export function Analytics() {
  if (!isProductionSite()) return null
  const gtmId = process.env.NEXT_PUBLIC_GTM_ID
  const cloudflareBeaconToken = process.env.NEXT_PUBLIC_CF_BEACON_TOKEN
  return (
    <>
      {gtmId ? <GoogleTagManager gtmId={gtmId} /> : null}
      {cloudflareBeaconToken ? (
        <Script
          src="https://static.cloudflareinsights.com/beacon.min.js"
          data-cf-beacon={JSON.stringify({ token: cloudflareBeaconToken })}
          strategy="afterInteractive"
        />
      ) : null}
    </>
  )
}
