import { BadgeCheck, Cpu, HardDrive, Laptop, Package, Tag } from 'lucide-react'
import Link from 'next/link'
import type { CSSProperties, ReactNode } from 'react'
import { Breadcrumbs } from '@/components/breadcrumbs'
import { CtaBand } from '@/components/cta-band'
import { Faq } from '@/components/faq'
import { KeybumpsAvatar } from '@/components/keybumps-avatar'
import { PluginIcon } from '@/components/plugin-icon'
import { linkPrefetch } from '@/lib/pages'
import {
  iconTints,
  keycaps,
  otherPlugins,
  type Plugin,
  type PluginPermission,
  pluginFor,
  pluginPath
} from '@/lib/plugins'
import { MINIMUM_MACOS } from '@/lib/site'

/**
 * A plugin's page, /plugins/<slug>/: a header in its tint, then its overview, features, commands,
 * and permissions beside a sidebar of facts and other plugins. `download` and `closingDownload` are
 * the Download buttons in the header and the closing call to action, which the page renders on the
 * server with the current DMG (`DownloadLink`).
 */
export function PluginDetail({
  plugin,
  download,
  closingDownload
}: {
  plugin: Plugin
  download: ReactNode
  closingDownload: ReactNode
}) {
  return (
    <main className="plugin-page" style={{ '--tint': iconTints[plugin.tint] } as CSSProperties}>
      <section className="plugin-page-hero">
        <div className="plugins-wrap">
          <Breadcrumbs
            trail={[
              { label: 'Home', href: '/' },
              { label: 'Plugins', href: '/plugins/' },
              { label: plugin.name, href: pluginPath(plugin.slug) }
            ]}
          />
        </div>
        <div className="plugins-wrap plugin-page-hero-inner">
          <div className="plugin-identity">
            <PluginIcon systemImage={plugin.systemImage} tint={plugin.tint} size={72} />
            <div className="plugin-identity-text">
              <h1>{plugin.name}</h1>
              <p className="plugin-tagline">{plugin.summary}</p>
              <ul className="plugin-meta">
                <li className="plugin-meta-item">
                  <KeybumpsAvatar />
                  Keybumps
                </li>
                <li className="plugin-meta-item">
                  <BadgeCheck aria-hidden="true" size={15} />
                  Official
                </li>
                <li className="plugin-meta-item">
                  <Tag aria-hidden="true" size={15} />
                  {plugin.category}
                </li>
                <li className="plugin-meta-item">
                  <Package aria-hidden="true" size={15} />
                  Included in Keybumps
                </li>
              </ul>
            </div>
          </div>
          <div className="plugin-actions">
            {download}
            <Link href="/plugins/" className="btn btn-ghost">
              All plugins
            </Link>
          </div>
        </div>
      </section>

      <div className="plugins-wrap">
        <nav className="plugin-tabs-row" aria-label="On this page">
          <span className="plugin-tabs">
            <a href="#overview">Overview</a>
            <a href="#how-to">How to use it</a>
            <a href="#commands">Commands</a>
            <a href="#privacy">Privacy</a>
            <a href="#questions">Questions</a>
          </span>
        </nav>

        <div className="plugin-body">
          <div className="plugin-main">
            <section id="overview" aria-labelledby="overview-heading">
              <h2 id="overview-heading" className="sr-only">
                Overview
              </h2>
              {plugin.overview.map(paragraph => (
                <p key={paragraph}>{paragraph}</p>
              ))}
              <AtAGlance plugin={plugin} />
            </section>

            <section id="how-to" aria-labelledby="how-to-heading">
              <h2 id="how-to-heading">How to use it</h2>
              <ol className="how-to">
                {plugin.howTo.map(step => (
                  <li key={step.text}>
                    <span>{step.text}</span>
                    {step.keys && <Keycaps keys={step.keys} />}
                  </li>
                ))}
              </ol>
            </section>

            <section aria-labelledby="features-heading">
              <h2 id="features-heading">Key features</h2>
              <ul className="feature-list">
                {plugin.features.map(feature => (
                  <li key={feature}>{feature}</li>
                ))}
              </ul>
            </section>

            <section id="commands" aria-labelledby="commands-heading">
              <h2 id="commands-heading">Commands</h2>
              <Commands plugin={plugin} />
            </section>

            <section id="privacy" aria-labelledby="privacy-heading">
              <h2 id="privacy-heading">Permissions and privacy</h2>
              <Permissions plugin={plugin} />
              <div className="plugin-keeps">
                <h3>
                  <HardDrive aria-hidden="true" size={16} className="muted-icon" />
                  What it keeps on your Mac
                </h3>
                {plugin.keeps.map(line => (
                  <p key={line}>{line}</p>
                ))}
              </div>
            </section>

            <section id="questions" aria-labelledby="questions-heading">
              <h2 id="questions-heading">Questions</h2>
              <Faq questions={plugin.faq} />
            </section>
          </div>

          <aside className="plugin-sidebar" aria-label={`About ${plugin.name}`}>
            <div>
              <h2 className="sidebar-label">Made by</h2>
              <p className="sidebar-row">
                <KeybumpsAvatar size={20} />
                Keybumps <span className="sidebar-muted">(Official)</span>
              </p>
            </div>
            <div>
              <h2 className="sidebar-label">Compatibility</h2>
              <ul className="sidebar-list">
                <li className="sidebar-item">
                  <Laptop aria-hidden="true" size={16} className="muted-icon" />
                  {`macOS ${plugin.minimumMacOS ?? MINIMUM_MACOS} or later`}
                </li>
                <li className="sidebar-item">
                  <Cpu aria-hidden="true" size={16} className="muted-icon" />
                  Apple silicon
                </li>
              </ul>
            </div>
            <div>
              <h2 className="sidebar-label">Category</h2>
              <span className="chip">{plugin.category}</span>
            </div>
            {plugin.requires.length > 0 && (
              <div>
                <h2 className="sidebar-label">Requires</h2>
                <ul className="sidebar-list">
                  {plugin.requires.map(pluginFor).map(required => (
                    <li key={required.slug} className="sidebar-item">
                      <Link
                        href={pluginPath(required.slug)}
                        prefetch={linkPrefetch(pluginPath(required.slug))}
                        className="sidebar-link"
                      >
                        <PluginIcon
                          systemImage={required.systemImage}
                          tint={required.tint}
                          size={20}
                        />
                        {required.name}
                      </Link>
                    </li>
                  ))}
                </ul>
              </div>
            )}
            <div>
              <h2 className="sidebar-label">Other plugins</h2>
              <ul className="other-plugins">
                {otherPlugins(plugin.slug).map(other => (
                  <li key={other.slug}>
                    <Link
                      href={pluginPath(other.slug)}
                      prefetch={linkPrefetch(pluginPath(other.slug))}
                    >
                      <PluginIcon systemImage={other.systemImage} tint={other.tint} size={32} />
                      <span className="other-text">
                        <span className="other-name">{other.name}</span>
                        <span className="other-summary">{other.summary}</span>
                      </span>
                    </Link>
                  </li>
                ))}
              </ul>
            </div>
          </aside>
        </div>

        <div className="plugin-cta">
          <CtaBand title={`Get ${plugin.name} with Keybumps.`} action={closingDownload}>
            {plugin.minimumMacOS && `Apple silicon · macOS ${plugin.minimumMacOS} or later`}
          </CtaBand>
        </div>
      </div>
    </main>
  )
}

/** Three facts under the overview: how it opens, its palette tab, and its permissions. */
function AtAGlance({ plugin }: { plugin: Plugin }) {
  // Only shortcuts that work from any app say how the plugin opens; Cancel Dictation doesn't.
  const assigned = plugin.shortcuts.filter(shortcut => shortcut.keys && !shortcut.note)
  const hotkey = assigned[0]?.keys
  // A plugin with shortcuts that start unassigned can be given one; one without shortcuts can't.
  const noHotkey = plugin.shortcuts.length > 0 ? 'Not set by default' : 'None'
  const tab = plugin.paletteTab
  const items: { label: string; value: ReactNode }[] = [
    {
      label: assigned.length > 1 ? 'Shortcuts' : 'Shortcut',
      value: hotkey ? (
        <span className="glance-tab">
          {assigned.length > 1 && `${assigned.length} by default, such as`}
          <Keycaps keys={hotkey} />
        </span>
      ) : (
        noHotkey
      )
    },
    {
      label: 'Command Palette tab',
      value: tab ? (
        <span className="glance-tab">
          {tab.name} <Keycaps keys={`⌘${tab.commandKey}`} />
          {tab.hiddenUnless && <span className="glance-note">once you turn it on</span>}
        </span>
      ) : (
        'None'
      )
    },
    {
      label: 'macOS permissions',
      value: (
        <span className="glance-tab">
          {plugin.permissions.length > 0
            ? plugin.permissions.map(item => item.permission).join(', ')
            : 'None needed'}
          {plugin.optionalPermissions && (
            <span className="glance-note">
              Optional: {plugin.optionalPermissions.map(item => item.permission).join(', ')}
            </span>
          )}
        </span>
      )
    }
  ]
  return (
    <dl className="at-a-glance">
      {items.map(item => (
        <div key={item.label}>
          <dt>{item.label}</dt>
          <dd>{item.value}</dd>
        </div>
      ))}
    </dl>
  )
}

function Keycaps({ keys }: { keys: string }) {
  return (
    <span className="keycaps">
      {keycaps(keys).map(key => (
        <kbd key={key}>{key}</kbd>
      ))}
    </span>
  )
}

function Commands({ plugin }: { plugin: Plugin }) {
  const tab = plugin.paletteTab
  const many = plugin.shortcuts.length > 6
  // A shortcut with a note (Cancel Dictation) works only at certain times, not from any app.
  const anywhere = plugin.shortcuts.every(shortcut => !shortcut.note)
  return (
    <>
      <p>
        {tab && plugin.shortcuts.length > 0
          ? `Open its tab in the Command Palette, or use its shortcuts${anywhere ? ' from any app' : ''}. You can change the shortcuts in Settings › ${plugin.name}.`
          : tab
            ? 'Open its tab in the Command Palette.'
            : `Its shortcuts work${anywhere ? ' from any app' : ' as noted below'}, and you can change any of them in Settings › ${plugin.name}.`}
      </p>
      {tab && (
        <ul className="command-list">
          <li className="command-row">
            <span className="command-name">
              {tab.name} tab
              <span className="command-note">
                {tab.hiddenUnless
                  ? `Command Palette, once you turn on “${tab.hiddenUnless}”`
                  : 'Command Palette'}
              </span>
            </span>
            <Keycaps keys={`⌘${tab.commandKey}`} />
          </li>
        </ul>
      )}
      {plugin.shortcuts.length > 0 && (
        <ul
          className={many ? 'command-list shortcut-list two-columns' : 'command-list shortcut-list'}
        >
          {plugin.shortcuts.map((shortcut, index) => (
            <li
              key={shortcut.title}
              className={
                many && index === plugin.shortcuts.length - 1 && index % 2 === 0
                  ? 'command-row command-row-wide'
                  : 'command-row'
              }
            >
              <span className="command-name">
                {shortcut.title}
                {shortcut.note && <span className="command-note">{shortcut.note}</span>}
              </span>
              {shortcut.keys ? (
                <Keycaps keys={shortcut.keys} />
              ) : (
                <span className="command-unset">Not set by default</span>
              )}
            </li>
          ))}
        </ul>
      )}
    </>
  )
}

function PermissionList({ items }: { items: readonly PluginPermission[] }) {
  return (
    <ul className="permission-list">
      {items.map(item => (
        <li key={item.permission} className="permission-row">
          <strong>{item.permission}</strong>
          <span>{item.reason}</span>
        </li>
      ))}
    </ul>
  )
}

function Permissions({ plugin }: { plugin: Plugin }) {
  return (
    <>
      {plugin.permissions.length > 0 ? (
        <>
          <p>
            {plugin.name} asks for {plugin.permissions.length === 1 ? 'this' : 'these'} macOS{' '}
            {plugin.permissions.length === 1 ? 'permission' : 'permissions'} while it’s on:
          </p>
          <PermissionList items={plugin.permissions} />
        </>
      ) : (
        <p>{plugin.name} needs no macOS permissions.</p>
      )}
      {plugin.optionalPermissions && (
        <>
          <p>
            {plugin.optionalPermissions.length === 1
              ? 'It can use this too, but works without it:'
              : 'It can use these too, but works without them:'}
          </p>
          <PermissionList items={plugin.optionalPermissions} />
        </>
      )}
    </>
  )
}
