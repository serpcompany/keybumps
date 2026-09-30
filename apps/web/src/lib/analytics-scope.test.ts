import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs'
import { dirname, join, relative, resolve, sep } from 'node:path'
import { describe, expect, it } from 'vitest'
import { noAnalyticsPaths } from './pages'

const srcDir = join(__dirname, '..')
const appDir = join(srcDir, 'app')
const analyticsGroup = '(analytics)'
const noAnalyticsGroup = '(no-analytics)'
const analyticsComponent = join(srcDir, 'components', 'analytics.tsx')
const sourceExtensions = ['.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs']

function files(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const full = join(dir, entry.name)
    return entry.isDirectory() ? files(full) : [full]
  })
}

/** Source files under src/, without tests. */
function sourceFiles() {
  return files(srcDir).filter(
    file => sourceExtensions.some(ext => file.endsWith(ext)) && !/\.test\.ts$/.test(file)
  )
}

/** Module specifiers from import, export-from, side-effect import, import(), and require(). */
function importSpecifiers(source: string) {
  const patterns = [
    /\b(?:import|export)\b[^'"]*?\bfrom\s*['"]([^'"]+)['"]/g,
    /\bimport\s*['"]([^'"]+)['"]/g,
    /\b(?:import|require)\s*\(\s*['"]([^'"]+)['"]\s*\)/g
  ]
  return patterns.flatMap(pattern => [...source.matchAll(pattern)].map(match => match[1]))
}

/** Resolves a relative or `@/` specifier to a file under src/, or null for a package. */
function resolveImport(fromFile: string, specifier: string) {
  let base: string
  if (specifier.startsWith('@/')) base = join(srcDir, specifier.slice(2))
  else if (specifier.startsWith('.')) base = resolve(dirname(fromFile), specifier)
  else return null
  const candidates = [
    base,
    ...sourceExtensions.map(ext => base + ext),
    ...sourceExtensions.map(ext => join(base, `index${ext}`))
  ]
  return candidates.find(candidate => existsSync(candidate) && statSync(candidate).isFile()) ?? null
}

/** Every page.tsx under src/app, with the URL it serves and its top-level route group. */
function appPages() {
  return files(appDir)
    .filter(file => file.endsWith(`${sep}page.tsx`))
    .map(file => {
      const segments = relative(appDir, file).split(sep).slice(0, -1)
      const routeSegments = segments.filter(segment => !/^\(.*\)$/.test(segment))
      return {
        url: routeSegments.length ? `/${routeSegments.join('/')}/` : '/',
        group: segments[0]
      }
    })
}

describe('analytics scope', () => {
  it('has two separate root layouts and no shared one, so crossing between them reloads', () => {
    expect(existsSync(join(appDir, 'layout.tsx'))).toBe(false)
    const layouts = files(appDir)
      .filter(file => file.endsWith(`${sep}layout.tsx`))
      .map(file => relative(appDir, file))
    expect(layouts.sort()).toEqual(
      [join(analyticsGroup, 'layout.tsx'), join(noAnalyticsGroup, 'layout.tsx')].sort()
    )
    for (const layout of layouts) {
      // Each renders its own <html> and <body> through SiteDocument.
      expect(readFileSync(join(appDir, layout), 'utf8'), layout).toContain('<SiteDocument>')
    }
    expect(readFileSync(join(srcDir, 'components', 'site-document.tsx'), 'utf8')).toContain('<html')
  })

  it('renders analytics only from the analytics component and the analytics root layout', () => {
    const allowed = [
      join('components', 'analytics.tsx'),
      join('app', analyticsGroup, 'layout.tsx')
    ].sort()
    // Imports are resolved to files, so any path to the analytics component counts, whatever the
    // specifier (`@/components/analytics`, `./analytics`, `../components/analytics`) and local name
    // (`import { Analytics as Tracking }`), including re-exports and dynamic imports. Other tools
    // are matched by module or name: @next/third-parties (GoogleTagManager, GoogleAnalytics, and
    // the rest), gtag, and the Cloudflare beacon.
    const markers = [
      /['"]@next\/third-parties/,
      /<Analytics\b/,
      /GoogleTagManager|GoogleAnalytics/,
      /googletagmanager|google-analytics|gtag\(/i,
      /cloudflareinsights/i
    ]
    const found = sourceFiles()
      .filter(file => {
        const source = readFileSync(file, 'utf8')
        const importsAnalytics = importSpecifiers(source).some(
          specifier => resolveImport(file, specifier) === analyticsComponent
        )
        return importsAnalytics || markers.some(marker => marker.test(source))
      })
      .map(file => relative(srcDir, file))
      .sort()
    expect(found).toEqual(allowed)
  })

  it('resolves every form of import of the analytics component', () => {
    const footer = join(srcDir, 'components', 'site-footer.tsx')
    const source = [
      "import { Analytics as Tracking } from './analytics'",
      "export { Analytics } from '../components/analytics.tsx'",
      "const Lazy = dynamic(() => import('@/components/analytics'))",
      "const Old = require('./analytics')"
    ].join('\n')
    const specifiers = importSpecifiers(source)
    expect(specifiers).toHaveLength(4)
    for (const specifier of specifiers) {
      expect(resolveImport(footer, specifier), specifier).toBe(analyticsComponent)
    }
    expect(resolveImport(footer, '@next/third-parties/google')).toBeNull()
  })

  it('strips the query string on every document without analytics', () => {
    for (const file of [
      join(appDir, noAnalyticsGroup, 'layout.tsx'),
      join(appDir, 'global-not-found.tsx')
    ]) {
      expect(readFileSync(file, 'utf8'), relative(srcDir, file)).toContain('<StripQuery />')
    }
  })

  it('serves pages whose URLs carry checkout, session, or license data from the no-analytics layout', () => {
    const pages = appPages()
    for (const path of noAnalyticsPaths) {
      const page = pages.find(candidate => candidate.url === path)
      expect(page, path).toBeDefined()
      expect(page?.group, path).toBe(noAnalyticsGroup)
    }
  })

  it('serves every other page from the analytics layout', () => {
    const excluded: readonly string[] = noAnalyticsPaths
    for (const page of appPages()) {
      expect(page.group, page.url).toBe(
        excluded.includes(page.url) ? noAnalyticsGroup : analyticsGroup
      )
    }
  })
})
