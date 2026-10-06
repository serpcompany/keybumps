import { BadgeCheck, Cpu, HardDrive, Laptop, Package, Tag } from 'lucide-react'
import Link from 'next/link'
import type { CSSProperties, ReactNode } from 'react'
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

/**
 * A plugin's page, /plugins/<slug>/: a header in its tint, then its overview, features, commands,
 * and permissions beside a sidebar of facts and other plugins. `download` is the Download button,
 * which the page renders on the server with the current DMG (`DownloadLink`).
 */
export function PluginDetail({ plugin, download }: { plugin: Plugin; download: ReactNode }) {
  return (
    <main className="plugin-page" style={{ '--tint': iconTints[plugin.tint] } as CSSProperties}>
      <section className="plugin-page-hero">
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
            <a href="#commands">Commands</a>
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
              <h2 className="plugin-subheading">Key features</h2>
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
                  macOS 14.2 or later
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
      </div>
    </main>
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
  return (
    <>
      <p>
        {tab && plugin.shortcuts.length > 0
          ? `Open its tab in the Command Palette, or use its shortcuts from any app. You can change the shortcuts in Settings › ${plugin.name}.`
          : tab
            ? 'Open its tab in the Command Palette.'
            : `Its shortcuts work from any app, and you can change any of them in Settings › ${plugin.name}.`}
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
              <span className="command-name">{shortcut.title}</span>
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
