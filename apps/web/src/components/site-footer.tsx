import Image from 'next/image'
import Link from 'next/link'
import { DownloadLink } from '@/components/download-link'
import { linkPrefetch } from '@/lib/pages'
import { pluginPath, plugins } from '@/lib/plugins'

type FooterLink = { href: string; label: string }

/** The footer's link groups. New page types (#181) add a group or links here when they ship. */
export const footerGroups: readonly { title: string; links: readonly FooterLink[] }[] = [
  {
    title: 'Product',
    links: [
      { href: '/plugins/', label: 'All plugins' },
      { href: '/pricing/', label: 'Pricing' },
      { href: '/changelog/', label: 'Changelog' }
    ]
  },
  {
    title: 'Plugins',
    links: plugins.map(plugin => ({ href: pluginPath(plugin.slug), label: plugin.name }))
  },
  {
    title: 'Help',
    links: [
      { href: '/support/', label: 'Support' },
      { href: '/license/', label: 'Lost your key?' },
      { href: '/contact/', label: 'Contact' }
    ]
  },
  {
    title: 'Company',
    links: [
      { href: '/about/', label: 'About' },
      { href: '/sitemap/', label: 'Sitemap' }
    ]
  },
  {
    title: 'Legal',
    links: [
      { href: '/legal/terms/', label: 'Terms' },
      { href: '/legal/privacy/', label: 'Privacy' },
      { href: '/legal/refunds/', label: 'Refunds' },
      { href: '/legal/dmca/', label: 'DMCA' },
      { href: '/legal/affiliate-disclosure/', label: 'Affiliate disclosure' },
      { href: '/legal/', label: 'All legal' }
    ]
  }
]

export function SiteFooter() {
  return (
    <footer className="footer">
      <div className="container footer-grid">
        <div className="footer-brand">
          <Link href="/" className="brand">
            <Image src="/brand/app-icon.png" alt="" width={28} height={28} />
            Keybumps
          </Link>
          <p>Mac utilities, one keyboard shortcut away.</p>
          <DownloadLink className="btn btn-sm">Download for macOS</DownloadLink>
        </div>
        <nav aria-label="Footer" className="footer-nav">
          {footerGroups.map(group => (
            <div key={group.title} className="footer-group">
              <h2>{group.title}</h2>
              <ul>
                {group.links.map(link => (
                  <li key={link.href}>
                    <Link href={link.href} prefetch={linkPrefetch(link.href)}>
                      {link.label}
                    </Link>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </nav>
      </div>
      <div className="container footer-base">
        <span>© {new Date().getFullYear()} SERP. Keybumps is a macOS app.</span>
      </div>
    </footer>
  )
}
