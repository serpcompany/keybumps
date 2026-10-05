import { PluginIcon } from '@/components/plugin-icon'
import { pageMetadata } from '@/lib/metadata'
import {
  type Plugin,
  permissionNames,
  pluginCategories,
  pluginFor,
  plugins,
  pluginsIn
} from '@/lib/plugins'

export const metadata = pageMetadata('/plugins/')

/**
 * The category filter is a radio group that site.css reads with :has(), so it needs no client
 * code. Each value is a category in lowercase, matching the cards' data-category.
 */
const filters = [
  { value: 'all', label: 'All', count: plugins.length },
  ...pluginCategories.map(category => ({
    value: category.toLowerCase(),
    label: category,
    count: pluginsIn(category).length
  }))
]

/**
 * The Store: every plugin, from the app's plugin manifests (src/lib/plugins.ts). The app opens it
 * from Settings › Plugins and Quick Search's Store command, at https://keybumps.app/plugins.
 */
export default function PluginsPage() {
  return (
    <main className="plugins">
      <section className="hero plugins-hero">
        <div className="container hero-inner">
          <span className="pill">
            <span className="dot" /> Store · {plugins.length} plugins
          </span>
          <h1>Plugins</h1>
          <p className="lede">
            Every plugin is official, built by Keybumps, and ships in the app. Turn each one on or
            off in Settings › Plugins.
          </p>
        </div>
      </section>

      <section className="section plugins-list" aria-labelledby="plugins-heading">
        <div className="container">
          <h2 id="plugins-heading" className="sr-only">
            Every plugin
          </h2>
          <fieldset className="plugin-filter">
            <legend className="sr-only">Show plugins in</legend>
            {filters.map(filter => (
              <span key={filter.value}>
                <input
                  type="radio"
                  name="category"
                  id={`category-${filter.value}`}
                  value={filter.value}
                  defaultChecked={filter.value === 'all'}
                  className="sr-only"
                />
                <label htmlFor={`category-${filter.value}`}>
                  {filter.label} <span className="count">{filter.count}</span>
                </label>
              </span>
            ))}
          </fieldset>
          <ul className="grid plugin-grid">
            {plugins.map(plugin => (
              <li key={plugin.slug} id={plugin.slug} data-category={plugin.category.toLowerCase()}>
                <PluginCard plugin={plugin} />
              </li>
            ))}
          </ul>
        </div>
      </section>
    </main>
  )
}

function PluginCard({ plugin }: { plugin: Plugin }) {
  return (
    <article className="card plugin-card">
      <div className="plugin-head">
        <PluginIcon systemImage={plugin.systemImage} tint={plugin.tint} />
        <div className="plugin-title">
          <h3>
            {plugin.name}
            {plugin.isNew && (
              <>
                {' '}
                <span className="plugin-new">New</span>
              </>
            )}
          </h3>
          <p className="plugin-by">Official · by Keybumps</p>
        </div>
        <span className="plugin-category">{plugin.category}</span>
      </div>
      <p>{plugin.summary}</p>
      <dl className="plugin-facts">
        <div>
          <dt>Palette tab</dt>
          <dd>
            {plugin.paletteTab ? (
              <>
                {plugin.paletteTab.name} <kbd>⌘{plugin.paletteTab.commandKey}</kbd>
                {plugin.paletteTab.hiddenUnless && (
                  <span className="plugin-note">
                    Hidden until you turn on “{plugin.paletteTab.hiddenUnless}”.
                  </span>
                )}
              </>
            ) : (
              'None'
            )}
          </dd>
        </div>
        <div>
          <dt>{plugin.shortcuts.length > 1 ? 'Shortcuts' : 'Shortcut'}</dt>
          <dd>
            {plugin.shortcuts.length === 0 ? (
              'None'
            ) : (
              <ul className="plugin-shortcuts">
                {plugin.shortcuts.map(shortcut => (
                  <li key={shortcut.title}>
                    {shortcut.title}{' '}
                    {shortcut.keys ? (
                      <kbd>{shortcut.keys}</kbd>
                    ) : (
                      <span className="plugin-note-inline">not set by default</span>
                    )}
                  </li>
                ))}
                {plugin.moreShortcuts ? <li>and {plugin.moreShortcuts} more</li> : null}
              </ul>
            )}
          </dd>
        </div>
        <div>
          <dt>Permissions</dt>
          <dd>
            {permissionNames(plugin.permissions) || 'None'}
            {plugin.optionalPermissions && (
              <span className="plugin-note">Optional: {plugin.optionalPermissions}</span>
            )}
          </dd>
        </div>
        {plugin.requires.length > 0 && (
          <div>
            <dt>Requires</dt>
            <dd>{plugin.requires.map(slug => pluginFor(slug).name).join(', ')}</dd>
          </div>
        )}
      </dl>
    </article>
  )
}
