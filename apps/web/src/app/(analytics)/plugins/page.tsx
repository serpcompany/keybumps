import { Layers, Tag } from 'lucide-react'
import Link from 'next/link'
import { KeybumpsAvatar } from '@/components/keybumps-avatar'
import { PluginBrowser, type PluginBrowserEntry } from '@/components/plugin-browser'
import { PluginIcon } from '@/components/plugin-icon'
import { pageMetadata } from '@/lib/metadata'
import { linkPrefetch } from '@/lib/pages'
import {
  commandCount,
  type Plugin,
  pluginCategories,
  pluginFor,
  pluginPath,
  plugins,
  searchTerms
} from '@/lib/plugins'

export const metadata = pageMetadata('/plugins/')

/** The filter tabs under the search. Category values match `PluginBrowserEntry.category`. */
const filters = [
  { value: 'all', label: 'All Plugins' },
  { value: 'new', label: 'New' },
  ...pluginCategories.map(category => ({ value: category.toLowerCase(), label: category }))
]

/**
 * The floating icons above the title: two staggered rows, the middle tiles largest and brightest.
 * Every plugin appears once; `plugins.test.ts` doesn't check this, so add a new plugin here too.
 * Each is [slug, size in pixels, opacity].
 */
const heroIcons: readonly (readonly [string, number, number])[][] = [
  [
    ['snippets', 52, 0.35],
    ['quick-search', 68, 0.75],
    ['emoji-picker', 80, 1],
    ['timer', 68, 0.75],
    ['window-manager', 52, 0.35]
  ],
  [
    ['clipboard-history', 52, 0.35],
    ['dictation', 68, 0.75],
    ['translation', 80, 1],
    ['screenshot-tools', 68, 0.75],
    ['shortcut-coach', 52, 0.35]
  ]
]

/**
 * /plugins/: every plugin, from the app's plugin manifests (src/lib/plugins.ts), each linking to
 * its own page. The app links here from Settings › Plugins (Browse on keybumps.app). The search
 * and the filter tabs are the only client code (src/components/plugin-browser.tsx).
 */
export default function PluginsPage() {
  const entries: PluginBrowserEntry[] = plugins.map(plugin => ({
    slug: plugin.slug,
    category: plugin.category.toLowerCase(),
    isNew: Boolean(plugin.isNew),
    terms: searchTerms(plugin),
    card: <PluginCard plugin={plugin} />
  }))

  return (
    <main className="plugins">
      <PluginBrowser
        hero={<Hero />}
        filters={filters}
        entries={entries}
        heading="Plugins"
        subtitle="Every plugin is included with Keybumps. Open one to see its commands and what it keeps on your Mac."
      />
    </main>
  )
}

function Hero() {
  return (
    <>
      <div className="hero-icons" aria-hidden="true">
        {heroIcons.map(row => (
          <div key={row[0][0]} className="hero-icons-row">
            {row.map(([slug, size, opacity], index) => {
              const plugin = pluginFor(slug)
              return (
                <span
                  key={slug}
                  className="hero-icon"
                  style={{ opacity, animationDelay: `${index * -1.3}s` }}
                >
                  <PluginIcon systemImage={plugin.systemImage} tint={plugin.tint} size={size} />
                </span>
              )
            })}
          </div>
        ))}
      </div>
      <h1>Plugins</h1>
      <p className="plugins-lede">
        Every plugin is official, built by Keybumps, and ships in the app.
        <br className="wide-only" /> Turn each one on or off in Settings › Plugins.
      </p>
    </>
  )
}

function PluginCard({ plugin }: { plugin: Plugin }) {
  const commands = commandCount(plugin)
  const path = pluginPath(plugin.slug)
  return (
    <Link href={path} prefetch={linkPrefetch(path)} className="plugin-card">
      <div className="plugin-card-top">
        <PluginIcon systemImage={plugin.systemImage} tint={plugin.tint} size={24} />
        <h3>{plugin.name}</h3>
        {plugin.isNew && <span className="badge-new">New</span>}
        <span className="pill-included">Included</span>
      </div>
      <p className="plugin-card-summary">{plugin.summary}</p>
      <span className="plugin-card-meta">
        <span className="plugin-author">
          <KeybumpsAvatar />
          Keybumps
        </span>
        <span>
          <Layers aria-hidden="true" size={14} />
          {commands} {commands === 1 ? 'command' : 'commands'}
        </span>
        {plugin.paletteTab && (
          <span title={`Its Command Palette tab, ${plugin.paletteTab.name}`}>
            <kbd>⌘{plugin.paletteTab.commandKey}</kbd>
          </span>
        )}
        <span className="meta-category">
          <Tag aria-hidden="true" size={14} />
          {plugin.category}
        </span>
      </span>
    </Link>
  )
}
