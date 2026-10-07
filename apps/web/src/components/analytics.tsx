import { GoogleTagManager } from '@next/third-parties/google'
import Script from 'next/script'
import { ConsentBanner } from '@/components/consent-banner'
import { consentCountries, consentEvent, consentStorageKey } from '@/lib/consent'
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
      {gtmId ? (
        <>
          {/* Inline, so it runs as the page parses, before GTM loads after hydration. */}
          {/* biome-ignore lint/security/noDangerouslySetInnerHtml: a fixed script built from constants, with no visitor data. */}
          <script id="consent-defaults" dangerouslySetInnerHTML={{ __html: consentDefaults }} />
          <GoogleTagManager gtmId={gtmId} />
          <ConsentBanner />
        </>
      ) : null}
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

/**
 * Google Consent Mode defaults (#337): denied in the countries that choose first
 * (`lib/consent.ts`), granted elsewhere. A choice saved on this browser applies at once, and the
 * banner's choice applies when it's made. A choice made on the banner also pushes
 * `keybumps_consent` to the dataLayer, so GTM can fire a tag that waits for consent, such as Meta's
 * pixel, on that page. A saved choice doesn't push it: it applies before GTM loads, so the page's
 * own triggers already see it, and pushing it too would fire those tags twice.
 */
const consentDefaults = `window.dataLayer=window.dataLayer||[];function gtag(){dataLayer.push(arguments)}
gtag('consent','default',{ad_storage:'denied',ad_user_data:'denied',ad_personalization:'denied',analytics_storage:'denied',region:${JSON.stringify(consentCountries)},wait_for_update:500});
gtag('consent','default',{ad_storage:'granted',ad_user_data:'granted',ad_personalization:'granted',analytics_storage:'granted'});
function keybumpsConsent(c,announce){if(c!=='granted'&&c!=='denied')return;gtag('consent','update',{ad_storage:c,ad_user_data:c,ad_personalization:c,analytics_storage:c});if(announce)dataLayer.push({event:'keybumps_consent',keybumps_consent:c})}
try{keybumpsConsent(localStorage.getItem(${JSON.stringify(consentStorageKey)}),false)}catch(e){}
addEventListener(${JSON.stringify(consentEvent)},function(e){keybumpsConsent(e.detail,true)});`
