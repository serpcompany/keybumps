import { readdirSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import type { Metadata } from 'next'
import { createElement, type ReactElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { beforeAll, describe, expect, it } from 'vitest'
import { PluginDetail } from '@/components/plugin-detail'
import { PluginPage } from '@/components/plugin-page'
import { pluginMetadata } from './metadata'
import { indexablePages, sitePages } from './pages'
import {
  cardShortcut,
  commandCount,
  iconTints,
  keycaps,
  macPermissions,
  otherPlugins,
  type Plugin,
  permissionNames,
  pluginCategories,
  pluginFor,
  pluginPath,
  plugins,
  searchTerms
} from './plugins'

/** A plugin's page as HTML, with a stand-in for the Download button (it reads latest.json). */
function renderPage(plugin: Plugin): string {
  return renderToStaticMarkup(
    createElement(PluginDetail, {
      plugin,
      download: createElement('a', { href: '#download' }, 'Download Keybumps'),
      closingDownload: createElement('a', { href: '#download' }, 'Download for macOS')
    })
  )
}

/** src/app/(analytics)/plugins/, where each plugin has its own static route. */
const pluginsDir = fileURLToPath(new URL('../app/(analytics)/plugins/', import.meta.url))

/** A plugin's route module, src/app/(analytics)/plugins/<slug>/page.tsx. */
async function routeModule(slug: string) {
  return (await import(join(pluginsDir, slug, 'page.tsx'))) as {
    default: () => ReactElement<{ slug: string }>
    metadata: Metadata
  }
}

/** The links in a page's Other plugins list. */
function otherPluginLinks(html: string): string[] {
  const list = html.split('class="other-plugins"')[1]?.split('</ul>')[0] ?? ''
  return [...list.matchAll(/href="([^"]+)"/g)].map(match => match[1])
}

describe('cardShortcut', () => {
  it('shows a default hotkey first, as one that works from any app', () => {
    expect(cardShortcut(pluginFor('quick-search'))).toEqual({
      keys: '⌘ Space',
      label: 'Open Quick Search, from any app'
    })
  })

  it('names the plugin when the hotkey’s title doesn’t', () => {
    expect(cardShortcut(pluginFor('window-manager'))?.label).toBe(
      'Window Manager: Left, from any app'
    )
    expect(cardShortcut(pluginFor('screenshot-tools'))?.label).toBe(
      'Screenshot Screen, from any app'
    )
  })

  it('falls back to the Command Palette tab when no hotkey is assigned', () => {
    expect(cardShortcut(pluginFor('snippets'))).toEqual({
      keys: '⌘5',
      label: 'Its Command Palette tab, Snippets'
    })
  })

  it('shows nothing for a tab hidden until a setting shows it', () => {
    expect(cardShortcut(pluginFor('shortcut-coach'))).toBeNull()
  })
})

describe('plugins', () => {
  it('gives each plugin a unique slug, usable in a URL', () => {
    const slugs = plugins.map(plugin => plugin.slug)
    expect(new Set(slugs).size).toBe(slugs.length)
    for (const slug of slugs) expect(slug).toMatch(/^[a-z]+(-[a-z]+)*$/)
  })

  it('names each plugin and its capability once', () => {
    for (const key of ['name', 'capability'] as const) {
      const values = plugins.map(plugin => plugin[key])
      expect(new Set(values).size, key).toBe(values.length)
    }
  })

  it('lists every plugin in one of the three categories', () => {
    expect(pluginCategories).toEqual(['Productivity', 'Writing', 'Media'])
    for (const plugin of plugins) expect(pluginCategories, plugin.slug).toContain(plugin.category)
  })

  it('uses only known tints and permissions, each with a reason', () => {
    for (const plugin of plugins) {
      expect(Object.keys(iconTints), plugin.slug).toContain(plugin.tint)
      for (const { permission, reason } of [
        ...plugin.permissions,
        ...(plugin.optionalPermissions ?? [])
      ]) {
        expect(macPermissions, plugin.slug).toContain(permission)
        expect(reason, `${plugin.slug} ${permission}`).toMatch(/^[A-Z].*\.$/)
      }
    }
  })

  it('selects each palette tab with its own Command-number', () => {
    const keys = plugins.flatMap(plugin =>
      plugin.paletteTab ? [plugin.paletteTab.commandKey] : []
    )
    expect(new Set(keys).size).toBe(keys.length)
  })

  it('requires only listed plugins, never itself', () => {
    for (const plugin of plugins) {
      for (const slug of plugin.requires) {
        expect(() => pluginFor(slug), plugin.slug).not.toThrow()
        expect(slug, plugin.slug).not.toBe(plugin.slug)
      }
    }
  })

  it('keeps the seven default capabilities apart from the added ones, and marks only added ones new', () => {
    expect(plugins.filter(plugin => plugin.isDefault).map(plugin => plugin.name)).toEqual([
      'Quick Search',
      'Clipboard History',
      'Screenshot Tools',
      'Dictation',
      'Window Manager',
      'Shortcut Coach',
      'Snippets'
    ])
    for (const plugin of plugins) {
      if (plugin.isNew) expect(plugin.isDefault, plugin.slug).toBe(false)
    }
  })

  it('gives every plugin an overview, key features, and what it keeps', () => {
    for (const plugin of plugins) {
      expect(plugin.overview.length, plugin.slug).toBeGreaterThanOrEqual(1)
      expect(plugin.overview.length, plugin.slug).toBeLessThanOrEqual(2)
      expect(plugin.features.length, plugin.slug).toBeGreaterThanOrEqual(3)
      expect(plugin.keeps.length, plugin.slug).toBeGreaterThanOrEqual(1)
      for (const text of [...plugin.overview, ...plugin.keeps]) expect(text).toMatch(/\.$/)
      for (const feature of plugin.features) expect(feature, plugin.slug).not.toMatch(/\.$/)
    }
  })

  it('lists all 30 of Window Manager’s window commands, all but Top Right with a shortcut', () => {
    const windowManager = pluginFor('window-manager')
    expect(windowManager.shortcuts).toHaveLength(30)
    expect(commandCount(windowManager)).toBe(30)
    expect(windowManager.shortcuts.filter(shortcut => !shortcut.keys)).toEqual([
      { title: 'Top Right', keys: null }
    ])
    const keys = windowManager.shortcuts.flatMap(shortcut => (shortcut.keys ? [shortcut.keys] : []))
    expect(new Set(keys).size).toBe(keys.length)
  })

  it('counts a plugin’s palette tab and shortcuts as its commands', () => {
    expect(commandCount(pluginFor('screenshot-tools'))).toBe(4)
    expect(commandCount(pluginFor('shortcut-coach'))).toBe(1)
    expect(commandCount(pluginFor('timer'))).toBe(2)
  })

  it('searches names, summaries, categories, tabs, and keywords', () => {
    expect(searchTerms(pluginFor('window-manager'))).toContain('snap')
    expect(searchTerms(pluginFor('timer'))).toContain('countdown')
    expect(searchTerms(pluginFor('dictation'))).toContain('writing')
    for (const plugin of plugins) {
      expect(searchTerms(plugin)).toBe(searchTerms(plugin).toLowerCase())
    }
  })

  it('splits shortcuts into one keycap per key', () => {
    expect(keycaps('⌘ Space')).toEqual(['⌘', 'Space'])
    expect(keycaps('⇧⌘ Space')).toEqual(['⇧', '⌘', 'Space'])
    expect(keycaps('⌃⌥⌘←')).toEqual(['⌃', '⌥', '⌘', '←'])
    expect(keycaps('⌃⌥⇧⌘9')).toEqual(['⌃', '⌥', '⇧', '⌘', '9'])
    expect(keycaps('⌃⌥-')).toEqual(['⌃', '⌥', '-'])
    expect(keycaps('⌘6')).toEqual(['⌘', '6'])
  })

  it('writes permission lists as the app does', () => {
    expect(permissionNames([])).toBe('')
    expect(permissionNames(['Accessibility'])).toBe('Accessibility')
    expect(permissionNames(['Speech Recognition', 'Microphone'])).toBe(
      'Microphone and Speech Recognition'
    )
    expect(permissionNames(['Speech Recognition', 'Accessibility', 'Microphone'])).toBe(
      'Accessibility, Microphone, and Speech Recognition'
    )
  })
})

describe('plugin pages', () => {
  // A build sets this from next.config.ts's `trailingSlash: true`; without it, <Link> drops the
  // trailing slash.
  beforeAll(() => {
    process.env.__NEXT_TRAILING_SLASH = 'true'
  })

  it('gives every plugin, and nothing else, a static route at /plugins/<slug>/', () => {
    // A static route per plugin, not a [slug] segment: OpenNext's default incremental cache never
    // holds the prerendered pages, and Next.js 404s a `dynamicParams = false` page on a cache
    // miss. Any other slug is unmatched, so it gets the global 404, which never loads analytics.
    const routes = readdirSync(pluginsDir, { withFileTypes: true })
      .filter(entry => entry.isDirectory())
      .map(entry => entry.name)
      .sort()
    expect(routes).toEqual(plugins.map(plugin => plugin.slug).sort())
    for (const plugin of plugins) expect(pluginPath(plugin.slug)).toBe(`/plugins/${plugin.slug}/`)
  })

  it('renders every slug’s page from its own plugin, with its own metadata', async () => {
    for (const plugin of plugins) {
      const route = await routeModule(plugin.slug)
      const page = route.default()
      expect(page.type, plugin.slug).toBe(PluginPage)
      expect(page.props.slug, plugin.slug).toBe(plugin.slug)
      expect(route.metadata, plugin.slug).toEqual(pluginMetadata(plugin))

      const html = renderPage(plugin)
      expect(html, plugin.slug).toContain(`<h1>${plugin.name}</h1>`)
      for (const id of ['overview', 'commands', 'privacy']) {
        expect(html, `${plugin.slug} #${id}`).toContain(`id="${id}"`)
      }
      expect(html, plugin.slug).toContain('href="/plugins/"')
      expect(html, plugin.slug).toContain('macOS 14.2 or later')
      expect(html, plugin.slug).toContain('Apple silicon')
    }
  })

  it('suggests three other plugins on each page, never the plugin itself', () => {
    for (const plugin of plugins) {
      const others = otherPlugins(plugin.slug)
      expect(others, plugin.slug).toHaveLength(3)
      expect(new Set(others).size, plugin.slug).toBe(3)
      expect(others, plugin.slug).not.toContain(plugin)

      const links = otherPluginLinks(renderPage(plugin))
      expect(links, plugin.slug).toEqual(others.map(other => pluginPath(other.slug)))
      expect(links, plugin.slug).not.toContain(pluginPath(plugin.slug))
    }
  })

  it('suggests every plugin from the same number of other pages', () => {
    const counts = new Map<string, number>()
    for (const plugin of plugins) {
      for (const other of otherPlugins(plugin.slug)) {
        counts.set(other.slug, (counts.get(other.slug) ?? 0) + 1)
      }
    }
    expect(new Set(counts.values())).toEqual(new Set([3]))
  })

  it('lists Requires only when a plugin needs another one', () => {
    expect(renderPage(pluginFor('screenshot-tools'))).toContain(
      'href="/plugins/clipboard-history/"'
    )
    expect(renderPage(pluginFor('timer'))).not.toContain('>Requires<')
  })

  it('puts every plugin page in the sitemaps, after the static pages', () => {
    const paths = indexablePages.map(page => page.path)
    expect(paths.slice(0, sitePages.length)).toEqual(sitePages.map(page => page.path))
    expect(paths.slice(sitePages.length)).toEqual(plugins.map(plugin => pluginPath(plugin.slug)))
    expect(new Set(paths).size).toBe(paths.length)
  })
})

describe('plugin page guides', () => {
  it('gives every plugin three how-to steps and at least three questions', () => {
    for (const plugin of plugins) {
      expect(plugin.howTo, plugin.slug).toHaveLength(3)
      expect(plugin.faq.length, plugin.slug).toBeGreaterThanOrEqual(3)
      expect(new Set(plugin.faq.map(item => item.q)).size, plugin.slug).toBe(plugin.faq.length)
    }
  })

  it('keeps engine and model names out of the guides', () => {
    const text = plugins.flatMap(plugin => [
      ...plugin.howTo.map(step => step.text),
      ...plugin.faq.flatMap(item => [item.q, item.a])
    ])
    expect(text.filter(line => /whisper|apple speech|model/i.test(line))).toEqual([])
  })

  it('renders the breadcrumb, steps, and questions with their structured data', () => {
    for (const plugin of plugins) {
      const html = renderPage(plugin)
      const data = [...html.matchAll(/<script type="application\/ld\+json">(.*?)<\/script>/g)].map(
        match => JSON.parse(match[1])
      )
      expect(data.map(item => item['@type']).sort(), plugin.slug).toEqual([
        'BreadcrumbList',
        'FAQPage'
      ])
      const faq = data.find(item => item['@type'] === 'FAQPage')
      expect(faq.mainEntity.map((item: { name: string }) => item.name)).toEqual(
        plugin.faq.map(item => item.q)
      )
      expect(html).toContain('aria-label="Breadcrumb"')
      expect(html).toContain('id="how-to"')
      expect(html).toContain('id="questions"')
    }
  })
})

describe('plugin page at a glance', () => {
  const glance = (slug: string) =>
    renderPage(pluginFor(slug)).split('class="at-a-glance"')[1]?.split('</dl>')[0] ?? ''

  it('says None for a plugin without shortcuts, and Not set by default for an unassigned one', () => {
    expect(glance('shortcut-coach')).toContain('<dd>None</dd>')
    expect(glance('snippets')).toContain('<dd>Not set by default</dd>')
  })

  it('counts default shortcuts when there are several, and names optional permissions', () => {
    expect(glance('window-manager')).toContain('29 by default, such as')
    expect(glance('clipboard-history')).not.toContain('by default, such as')
    expect(glance('snippets')).toContain('Optional: Accessibility, Input Monitoring')
  })

  it('says when a Command Palette tab is hidden until turned on', () => {
    expect(glance('shortcut-coach')).toContain('once you turn it on')
    expect(glance('clipboard-history')).not.toContain('once you turn it on')
  })
})
