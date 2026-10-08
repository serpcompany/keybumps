import Image from 'next/image'
import Link from 'next/link'
import { DownloadLink } from '@/components/download-link'
import { PluginIcon } from '@/components/plugin-icon'
import { type NavMenu, SiteNav } from '@/components/site-nav'
import { pluginCategories, pluginPath, pluginsIn } from '@/lib/plugins'

/**
 * The header's menus. Add Features, Use cases, Compare, Manual, and Blog here when those pages
 * ship (#181); a menu never points at a page that doesn't exist.
 */
export const headerMenus: readonly NavMenu[] = [
  {
    label: 'Plugins',
    wide: true,
    groups: pluginCategories.map(category => ({
      title: category,
      links: pluginsIn(category).map(plugin => ({
        href: pluginPath(plugin.slug),
        label: plugin.name,
        description: plugin.summary,
        icon: <PluginIcon systemImage={plugin.systemImage} tint={plugin.tint} size={28} />
      }))
    })),
    more: { href: '/plugins/', label: 'All plugins' }
  },
  { label: 'Pricing', href: '/pricing/' },
  {
    label: 'Resources',
    groups: [
      {
        links: [
          { href: '/support/', label: 'Support', description: 'Get help with Keybumps' },
          { href: '/changelog/', label: 'Changelog', description: "Every release's notes" },
          { href: '/license/', label: 'Lost your key?', description: 'Find your license key' },
          { href: '/contact/', label: 'Contact', description: 'Write to the team' },
          { href: '/about/', label: 'About', description: 'Who makes Keybumps' }
        ]
      }
    ]
  }
]

export function SiteHeader() {
  return (
    <header className="nav">
      <div className="container nav-inner">
        <Link href="/" className="brand">
          <Image src="/brand/app-icon.png" alt="" width={28} height={28} />
          Keybumps
        </Link>
        <SiteNav
          menus={headerMenus}
          download={<DownloadLink className="btn btn-sm">Download</DownloadLink>}
        />
      </div>
    </header>
  )
}
