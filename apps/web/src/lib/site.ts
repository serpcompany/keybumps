export const SUPPORT_EMAIL = 'support@keybumps.app'

/** Polar customer portal: purchases, license keys, and freeing a Mac. */
export const CUSTOMER_PORTAL_URL = 'https://polar.sh/serp/portal'

export const LEGAL_UPDATED = 'October 7, 2026'

/** A macOS version as the site writes it: 15 or 14.2, never empty. */
export type MacOSVersion = `${number}` | `${number}.${number}`

/** The oldest macOS Keybumps runs on: `deploymentTarget` in `apps/macos/project.yml`. */
export const MINIMUM_MACOS: MacOSVersion = '14.2'

export const site = {
  name: 'Keybumps',
  description:
    'Search, clipboard history, screenshots, on-device dictation, and more Mac utilities in one keyboard-first native macOS app.',
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
