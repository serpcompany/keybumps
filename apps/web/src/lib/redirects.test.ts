import { buildCustomRoute } from 'next/dist/lib/build-custom-route'
import { compile, match } from 'path-to-regexp'
import { describe, expect, it } from 'vitest'
import { indexablePages } from './pages'
import { siteRedirects, smokeTestHeader } from './redirects'

type Request = { host?: string; path: string; headers?: Record<string, string> }

/**
 * Resolves a request the way OpenNext does on Cloudflare: the first redirect whose Next.js route
 * regex and host/header conditions match wins, and path-to-regexp 6 fills the destination.
 * Returns the Location, or null when the request is served directly.
 */
function resolve(
  redirects: ReturnType<typeof siteRedirects>,
  { host = 'keybumps.app', path, headers = {} }: Request
) {
  const has = (condition: { type: string; key?: string; value?: string }) => {
    if (condition.type === 'host') return new RegExp(condition.value ?? '').test(host)
    if (condition.type === 'header') return condition.key ? condition.key in headers : false
    return false
  }
  for (const redirect of redirects) {
    // Next.js keeps redirects away from /_next/ with this restricted path.
    const route = buildCustomRoute('redirect', redirect, ['/_next'])
    if (!new RegExp(route.regex).test(path)) continue
    if (!(redirect.has ?? []).every(has)) continue
    if ((redirect.missing ?? []).some(has)) continue
    const params = (match(redirect.source)(path) || { params: {} }).params as Record<string, string>
    const { origin, pathname } = redirect.destination.startsWith('http')
      ? new URL(redirect.destination)
      : { origin: '', pathname: redirect.destination }
    const filled = Object.keys(params).length ? compile(pathname)(params) : pathname
    return `${origin}${filled}`
  }
  return null
}

const production = siteRedirects({ production: true })
const staging = siteRedirects({ production: false })

describe('site redirects', () => {
  it('serves every canonical page, file, and framework asset directly', () => {
    for (const path of [
      // The static pages and each plugin's page.
      ...indexablePages.map(page => page.path),
      // Its route handler answers with a temporary redirect to the current DMG, not a config one.
      '/download/',
      '/thanks/',
      '/robots.txt',
      '/sitemap-index.xml',
      '/sitemaps/pages.xml',
      '/_next/static/chunks/app.js',
      '/_next/image',
      '/.well-known/security.txt'
    ]) {
      expect(resolve(production, { path }), path).toBeNull()
    }
  })

  it('adds the trailing slash to pages and removes it from files, in one hop', () => {
    expect(resolve(production, { path: '/pricing' })).toBe('/pricing/')
    // The app's Settings › Plugins (Browse on keybumps.app) opens https://keybumps.app/plugins.
    expect(resolve(production, { path: '/plugins' })).toBe('/plugins/')
    expect(resolve(production, { path: '/legal/dmca' })).toBe('/legal/dmca/')
    // Old /download links take this one hop, then src/app/download/route.ts sends the DMG.
    expect(resolve(production, { path: '/download' })).toBe('/download/')
    expect(resolve(production, { path: '/robots.txt/' })).toBe('/robots.txt')
    expect(resolve(production, { path: '/sitemaps/pages.xml/' })).toBe('/sitemaps/pages.xml')
  })

  it('never redirects /api/ routes, with or without a slash', () => {
    for (const path of [
      '/api',
      '/api/',
      '/api/consent',
      '/api/consent/',
      '/api/webhooks/polar',
      '/api/webhooks/polar/'
    ]) {
      expect(resolve(production, { path }), path).toBeNull()
    }
    // A segment that only starts with "api" is an ordinary page and still gets its slash.
    expect(resolve(production, { path: '/apis' })).toBe('/apis/')
  })

  it('sends legacy URLs straight to their page', () => {
    for (const legacy of ['privacy', 'terms', 'refunds']) {
      expect(resolve(production, { path: `/${legacy}` })).toBe(`/legal/${legacy}/`)
      expect(resolve(production, { path: `/${legacy}/` })).toBe(`/legal/${legacy}/`)
    }
    expect(resolve(production, { path: '/sitemap.xml' })).toBe('/sitemap-index.xml')
  })

  it("sends ScreenGrabs' old page, Screenshot Tools', to its new one in one 308", () => {
    for (const path of ['/plugins/screenshot-tools', '/plugins/screenshot-tools/']) {
      expect(resolve(production, { path }), path).toBe('/plugins/screengrabs/')
      expect(resolve(staging, { path }), path).toBe('/plugins/screengrabs/')
    }
    // Permanent, so a 308: on keybumps.app, and from www and workers.dev straight to it.
    const rules = production.filter(redirect => redirect.source === '/plugins/screenshot-tools')
    expect(rules.map(rule => [rule.destination, rule.permanent])).toEqual([
      ['https://keybumps.app/plugins/screengrabs/', true],
      ['https://keybumps.app/plugins/screengrabs/', true],
      ['/plugins/screengrabs/', true]
    ])
    // Only that slug: the new page, and a slug that starts the same, aren't moved.
    expect(resolve(production, { path: '/plugins/screengrabs/' })).toBeNull()
    expect(resolve(production, { path: '/plugins/screenshot-tools-x/' })).toBeNull()
  })

  it('lands every non-canonical URL on a directly served URL in one hop', () => {
    for (const path of [
      '/pricing',
      '/plugins',
      '/download',
      '/license',
      '/thanks',
      '/about',
      '/legal',
      '/legal/dmca',
      '/legal/affiliate-disclosure',
      '/privacy',
      '/privacy/',
      '/terms',
      '/terms/',
      '/refunds',
      '/refunds/',
      '/plugins/screengrabs',
      '/plugins/screenshot-tools',
      '/plugins/screenshot-tools/',
      '/sitemap.xml',
      '/robots.txt/',
      '/sitemap-index.xml/',
      '/sitemaps/pages.xml/'
    ]) {
      const destination = resolve(production, { path })
      expect(destination, path).not.toBeNull()
      expect(destination, path).not.toBe(path)
      expect(
        resolve(production, { path: destination ?? '' }),
        `${path} -> ${destination}`
      ).toBeNull()
    }
  })

  it('moves www to the apex in one canonical hop', () => {
    const www = (path: string) => resolve(production, { host: 'www.keybumps.app', path })
    expect(www('/')).toBe('https://keybumps.app/')
    expect(www('/pricing')).toBe('https://keybumps.app/pricing/')
    expect(www('/pricing/')).toBe('https://keybumps.app/pricing/')
    expect(www('/privacy')).toBe('https://keybumps.app/legal/privacy/')
    expect(www('/plugins/screenshot-tools/')).toBe('https://keybumps.app/plugins/screengrabs/')
    expect(www('/robots.txt')).toBe('https://keybumps.app/robots.txt')
    expect(www('/sitemaps/pages.xml/')).toBe('https://keybumps.app/sitemaps/pages.xml')
  })

  it('matches only the exact www and workers.dev hosts', () => {
    for (const host of [
      'xwww.keybumps.app',
      'www.keybumps.app.example.com',
      'x.workers.dev.example.com'
    ]) {
      expect(resolve(production, { host, path: '/legal/terms/' }), host).toBeNull()
    }
  })

  it('moves workers.dev to the environment domain unless the smoke-test header is sent', () => {
    const host = 'keybumps-web-production.serp.workers.dev'
    expect(resolve(production, { host, path: '/legal/terms/' })).toBe(
      'https://keybumps.app/legal/terms/'
    )
    expect(resolve(staging, { host, path: '/legal/terms/' })).toBe(
      'https://staging.keybumps.app/legal/terms/'
    )
    const smoke = { [smokeTestHeader]: '1' }
    expect(resolve(production, { host, path: '/legal/terms/', headers: smoke })).toBeNull()
    expect(resolve(production, { host, path: '/privacy', headers: smoke })).toBe('/legal/privacy/')
  })
})
