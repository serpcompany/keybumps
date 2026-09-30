import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { join, relative, sep } from 'node:path'
import { describe, expect, it } from 'vitest'
import { noAnalyticsPaths } from './pages'

const srcDir = join(__dirname, '..')
const appDir = join(srcDir, 'app')
const analyticsGroup = '(analytics)'
const noAnalyticsGroup = '(no-analytics)'

function files(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const full = join(dir, entry.name)
    return entry.isDirectory() ? files(full) : [full]
  })
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
    const markers = ['<Analytics', 'GoogleTagManager', 'googletagmanager', 'cloudflareinsights']
    const found = files(srcDir)
      .filter(file => /\.(ts|tsx|js|jsx|mjs)$/.test(file) && !/\.test\.ts$/.test(file))
      .filter(file => {
        const source = readFileSync(file, 'utf8')
        return markers.some(marker => source.includes(marker))
      })
      .map(file => relative(srcDir, file))
      .sort()
    expect(found).toEqual(allowed)
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
