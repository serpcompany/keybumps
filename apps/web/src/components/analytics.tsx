import { GoogleTagManager } from '@next/third-parties/google'
import Script from 'next/script'
import { isProductionSite } from '@/lib/site'

/**
 * Production-only analytics, rendered only by the src/app/(analytics)/ route group layout, so
 * never on pages whose URLs carry checkout, session, or license data (/thanks/, /license/).
 * Each tool stays off until its ID is set at build time. Adding or changing a tool means updating
 * the privacy policy (/legal/privacy/) in the same change.
 *
 * The owner chose Google Tag Manager only. NEXT_PUBLIC_CF_BEACON_TOKEN must not be set until the
 * privacy policy covers Cloudflare Web Analytics.
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
