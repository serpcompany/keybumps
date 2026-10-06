'use client'

import { Menu, X } from 'lucide-react'
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { type ReactNode, useEffect, useRef, useState } from 'react'
import { linkPrefetch } from '@/lib/pages'

export type NavLink = {
  href: string
  label: string
  description?: string
  icon?: ReactNode
}

export type NavMenu =
  | { label: string; href: string }
  | {
      label: string
      groups: readonly { title?: string; links: readonly NavLink[] }[]
      /** A last link under the groups, such as "All plugins". */
      more?: NavLink
      wide?: boolean
    }

/**
 * The header's menus (src/components/site-header.tsx builds them). A menu opens on click, or on
 * hover with a pointer that can hover, and closes on Escape, a click outside, or a link click.
 * Below 900px the menus fold into one panel behind a menu button.
 */
export function SiteNav({ menus, download }: { menus: readonly NavMenu[]; download: ReactNode }) {
  const [open, setOpen] = useState<string | null>(null)
  const [panel, setPanel] = useState(false)
  const nav = useRef<HTMLElement>(null)
  const pathname = usePathname()

  // A link click that changes the page closes everything.
  // biome-ignore lint/correctness/useExhaustiveDependencies: runs on each new pathname.
  useEffect(() => {
    setOpen(null)
    setPanel(false)
  }, [pathname])

  useEffect(() => {
    function onKey(event: KeyboardEvent) {
      if (event.key === 'Escape') {
        setOpen(null)
        setPanel(false)
      }
    }
    function onPointer(event: PointerEvent) {
      if (nav.current && !nav.current.contains(event.target as Node)) setOpen(null)
    }
    document.addEventListener('keydown', onKey)
    document.addEventListener('pointerdown', onPointer)
    return () => {
      document.removeEventListener('keydown', onKey)
      document.removeEventListener('pointerdown', onPointer)
    }
  }, [])

  const canHover = () => window.matchMedia('(hover: hover) and (pointer: fine)').matches

  return (
    <nav
      ref={nav}
      className="site-nav"
      aria-label="Main"
      onPointerLeave={() => canHover() && setOpen(null)}
    >
      <ul className="nav-menus">
        {menus.map(menu =>
          'href' in menu ? (
            <li key={menu.label}>
              <Link href={menu.href} prefetch={linkPrefetch(menu.href)} className="nav-top">
                {menu.label}
              </Link>
            </li>
          ) : (
            <li
              key={menu.label}
              className="nav-item"
              onPointerEnter={() => canHover() && setOpen(menu.label)}
            >
              <button
                type="button"
                className="nav-top"
                aria-expanded={open === menu.label}
                onClick={() => setOpen(open === menu.label ? null : menu.label)}
              >
                {menu.label}
                <span className="nav-chevron" aria-hidden="true" />
              </button>
              <div
                className={menu.wide ? 'nav-panel nav-panel-wide' : 'nav-panel'}
                hidden={open !== menu.label}
              >
                <MenuGroups menu={menu} />
              </div>
            </li>
          )
        )}
      </ul>
      <div className="nav-actions">
        {download}
        <button
          type="button"
          className="nav-burger"
          aria-expanded={panel}
          aria-controls="nav-sheet"
          onClick={() => setPanel(!panel)}
        >
          {panel ? <X aria-hidden="true" size={20} /> : <Menu aria-hidden="true" size={20} />}
          <span className="sr-only">Menu</span>
        </button>
      </div>
      {/* Rendered only while open, so the header never carries a second copy of every link. */}
      {panel && (
        <div id="nav-sheet" className="nav-sheet">
          {menus.map(menu =>
            'href' in menu ? (
              <Link
                key={menu.label}
                href={menu.href}
                prefetch={linkPrefetch(menu.href)}
                className="nav-sheet-top"
              >
                {menu.label}
              </Link>
            ) : (
              <div key={menu.label} className="nav-sheet-group">
                <p className="nav-sheet-label">{menu.label}</p>
                <MenuGroups menu={menu} />
              </div>
            )
          )}
        </div>
      )}
    </nav>
  )
}

function MenuGroups({ menu }: { menu: Extract<NavMenu, { groups: unknown }> }) {
  return (
    <>
      <div className="nav-groups">
        {menu.groups.map(group => (
          <div key={group.title ?? menu.label} className="nav-group">
            {group.title && <p className="nav-group-title">{group.title}</p>}
            <ul>
              {group.links.map(link => (
                <li key={link.href}>
                  <Link href={link.href} prefetch={linkPrefetch(link.href)} className="nav-link">
                    {link.icon}
                    <span className="nav-link-text">
                      <span className="nav-link-label">{link.label}</span>
                      {link.description && (
                        <span className="nav-link-description">{link.description}</span>
                      )}
                    </span>
                  </Link>
                </li>
              ))}
            </ul>
          </div>
        ))}
      </div>
      {menu.more && (
        <Link href={menu.more.href} prefetch={linkPrefetch(menu.more.href)} className="nav-more">
          {menu.more.label} →
        </Link>
      )}
    </>
  )
}
