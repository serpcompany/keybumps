import { describe, expect, it } from 'vitest'
import { footerGroups } from '@/components/site-footer'
import { headerMenus } from '@/components/site-header'
import { indexablePages, sensitiveUrlPaths } from './pages'

const known = new Set<string>([...indexablePages.map(page => page.path), ...sensitiveUrlPaths])

function headerLinks(): string[] {
  return headerMenus.flatMap(menu =>
    'href' in menu
      ? [menu.href]
      : [
          ...menu.groups.flatMap(group => group.links.map(link => link.href)),
          ...(menu.more ? [menu.more.href] : [])
        ]
  )
}

describe('site header and footer', () => {
  it('link only to pages that exist', () => {
    const links = [...headerLinks(), ...footerGroups.flatMap(g => g.links.map(l => l.href))]
    expect(links.filter(href => !known.has(href))).toEqual([])
  })

  it('list every plugin in the Plugins menu and the footer', () => {
    const pluginPages = indexablePages.filter(page => /^\/plugins\/[^/]+\/$/.test(page.path))
    const footer = footerGroups.find(group => group.title === 'Plugins')?.links.map(l => l.href)
    for (const page of pluginPages) {
      expect(headerLinks()).toContain(page.path)
      expect(footer).toContain(page.path)
    }
  })
})
