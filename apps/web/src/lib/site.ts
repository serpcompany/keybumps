export const SUPPORT_EMAIL = 'support@keybumps.app'
export const PRICE = '$49'

/** Polar checkout link. When it is null, the buy button downloads the current DMG instead. */
export const CHECKOUT_URL: string | null =
  'https://buy.polar.sh/polar_cl_NgKwENo1kvvLio6Xl27IFyoWpAoqf73sN8mRX03RNTj'

/** Polar customer portal: purchases, license keys, and freeing a Mac. */
export const CUSTOMER_PORTAL_URL = 'https://polar.sh/serp/portal'

export const LEGAL_UPDATED = 'October 6, 2026'

export const site = {
  name: 'Keybumps',
  description:
    'Quick search, clipboard history, screenshots, on-device dictation, window management, and shortcut coaching in one native macOS app.',
  url: 'https://keybumps.app',
  supportEmail: SUPPORT_EMAIL
} as const

/**
 * Production is marked by SITE_ENV=production, both at build time (for next.config headers and
 * redirects, and statically rendered pages) and at runtime (the production Worker var, for anything
 * rendered on request). Anything else is non-production and kept out of search engines.
 */
export function isProductionSite() {
  return process.env.SITE_ENV === 'production'
}

export function absoluteUrl(path: string) {
  return new URL(path, site.url).toString()
}
