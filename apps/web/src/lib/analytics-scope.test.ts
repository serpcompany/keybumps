import { readdirSync, readFileSync } from 'node:fs'
import { join, relative, sep } from 'node:path'
import { describe, expect, it } from 'vitest'
import { noAnalyticsPaths } from './pages'

const appDir = join(__dirname, '..', 'app')
const analyticsGroup = '(analytics)'

/** Every page.tsx under src/app, with the URL it serves and whether it sits in the group. */
function appPages() {
  const pages: { url: string; inAnalyticsGroup: boolean }[] = []
  const walk = (dir: string) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const full = join(dir, entry.name)
      if (entry.isDirectory()) walk(full)
      else if (entry.name === 'page.tsx') {
        const segments = relative(appDir, dir).split(sep).filter(Boolean)
        const routeSegments = segments.filter(segment => !/^\(.*\)$/.test(segment))
        pages.push({
          url: routeSegments.length ? `/${routeSegments.join('/')}/` : '/',
          inAnalyticsGroup: segments[0] === analyticsGroup
        })
      }
    }
  }
  walk(appDir)
  return pages
}

/** Files that render <Analytics />. */
function analyticsRenderers(dir = appDir): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const full = join(dir, entry.name)
    if (entry.isDirectory()) return analyticsRenderers(full)
    if (!/\.tsx$/.test(entry.name)) return []
    return readFileSync(full, 'utf8').includes('<Analytics') ? [relative(appDir, full)] : []
  })
}

describe('analytics scope', () => {
  it('renders analytics only from the (analytics) route group layout', () => {
    expect(analyticsRenderers()).toEqual([join(analyticsGroup, 'layout.tsx')])
  })

  it('keeps pages whose URLs carry checkout, session, or license data out of the group', () => {
    const pages = appPages()
    for (const path of noAnalyticsPaths) {
      const page = pages.find(candidate => candidate.url === path)
      expect(page, path).toBeDefined()
      expect(page?.inAnalyticsGroup, path).toBe(false)
    }
  })

  it('puts every other page in the group', () => {
    const excluded: readonly string[] = noAnalyticsPaths
    for (const page of appPages()) {
      expect(page.inAnalyticsGroup, page.url).toBe(!excluded.includes(page.url))
    }
  })
})
