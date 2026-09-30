import { PRICE } from './site'

export type SitePage = {
  path: string
  title: string
  description: string
}

/**
 * Indexable static pages, in the order the HTML sitemap and the pages sitemap list them. Pages
 * that are kept out of search engines (/download/, /thanks/) are not listed.
 */
export const sitePages = [
  {
    path: '/',
    title: 'Home',
    description:
      'Quick search, clipboard history, screenshots, on-device dictation, window management, and shortcut coaching in one native macOS app.'
  },
  {
    path: '/pricing/',
    title: 'Pricing',
    description: `Keybumps is a ${PRICE} one-time purchase for one Mac, with a 30-day money-back guarantee.`
  },
  {
    path: '/license/',
    title: 'Find your license key',
    description: 'Find your Keybumps license key and manage the Mac it is activated on.'
  },
  { path: '/about/', title: 'About', description: 'About Keybumps.' },
  { path: '/support/', title: 'Support', description: 'Get help with Keybumps.' },
  { path: '/contact/', title: 'Contact', description: 'Contact the Keybumps team.' },
  { path: '/legal/', title: 'Legal', description: 'Keybumps legal policies.' },
  {
    path: '/legal/privacy/',
    title: 'Privacy Policy',
    description: 'How Keybumps handles your information. Short version: it stays on your Mac.'
  },
  {
    path: '/legal/terms/',
    title: 'Terms of Service',
    description: 'The terms that apply to buying and using Keybumps.'
  },
  {
    path: '/legal/refunds/',
    title: 'Refund Policy',
    description: 'Keybumps comes with a 30-day money-back guarantee.'
  },
  {
    path: '/legal/dmca/',
    title: 'DMCA Copyright Policy',
    description: 'How to report claimed copyright infringement to Keybumps.'
  },
  {
    path: '/legal/affiliate-disclosure/',
    title: 'Affiliate Disclosure',
    description: 'How Keybumps discloses affiliate relationships.'
  },
  { path: '/sitemap/', title: 'Sitemap', description: 'Every page on keybumps.app.' }
] as const satisfies readonly SitePage[]

export type SitePagePath = (typeof sitePages)[number]['path']

export const legalPages = sitePages.filter(
  page => page.path.startsWith('/legal/') && page.path !== '/legal/'
)

export function pageFor(path: SitePagePath): SitePage {
  const page = sitePages.find(candidate => candidate.path === path)
  if (!page) throw new Error(`Unknown page: ${path}`)
  return page
}

/**
 * Legacy URLs that shipped before the /legal/ section. Polar checkout review and older links use
 * them, so each one permanently redirects to its page in one hop.
 */
export const legacyRedirects = [
  { from: '/privacy', to: '/legal/privacy/' },
  { from: '/terms', to: '/legal/terms/' },
  { from: '/refunds', to: '/legal/refunds/' }
] as const satisfies readonly { from: string; to: SitePagePath }[]

/**
 * Pages whose URLs can carry checkout, session, or license data. Polar sends buyers to /thanks/
 * with a customer-session token in the query string, and /license/ is where they find their key.
 * They live in the src/app/(sensitive-url)/ root layout, which removes the query string before the
 * App Router or GTM can see it.
 */
export const sensitiveUrlPaths = ['/thanks/', '/license/'] as const

export type SensitiveUrlPath = (typeof sensitiveUrlPaths)[number]
