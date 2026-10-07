/**
 * Cookie consent for the live site's analytics and ad tags (#337). Visitors from the EU, the rest
 * of the EEA, the UK, and Switzerland choose before tags that set cookies run; everyone else gets
 * them by default. Cloudflare says which country a request comes from (`/api/consent/`), and
 * Google Consent Mode carries the choice to the tags in Google Tag Manager
 * (`components/analytics.tsx`).
 */

/** The EU, Iceland, Liechtenstein, and Norway (the EEA), the UK, and Switzerland. */
export const consentCountries = [
  'AT',
  'BE',
  'BG',
  'HR',
  'CY',
  'CZ',
  'DK',
  'EE',
  'FI',
  'FR',
  'DE',
  'GR',
  'HU',
  'IE',
  'IT',
  'LV',
  'LT',
  'LU',
  'MT',
  'NL',
  'PL',
  'PT',
  'RO',
  'SK',
  'SI',
  'ES',
  'SE',
  'IS',
  'LI',
  'NO',
  'GB',
  'CH'
] as const

/** Where the visitor's choice is kept, on their own browser only. */
export const consentStorageKey = 'keybumps-consent'
/** The DOM event the banner sends with the choice, which the consent script in `components/analytics.tsx` hears. */
export const consentEvent = 'keybumps:consent'

export type ConsentChoice = 'granted' | 'denied'

/**
 * Whether a visitor from `country` (Cloudflare's two-letter code) chooses first. An unknown
 * country (none, `XX`, or `T1` for Tor) asks too, to be safe.
 */
export function requiresConsent(country: string | null | undefined): boolean {
  const code = country?.trim().toUpperCase()
  if (!code || code === 'XX' || code === 'T1') return true
  return (consentCountries as readonly string[]).includes(code)
}

/** A stored choice, or null for anything else. */
export function storedConsent(value: string | null | undefined): ConsentChoice | null {
  return value === 'granted' || value === 'denied' ? value : null
}
