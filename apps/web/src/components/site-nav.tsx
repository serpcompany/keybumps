'use client'

import { Menu, X } from 'lucide-react'
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { type FocusEvent, type ReactNode, useCallback, useEffect, useRef, useState } from 'react'
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
      /** Spans the header's width instead of hanging from its button. */
      wide?: boolean
    }

const panelId = (label: string) => `nav-panel-${label.toLowerCase().replace(/\W+/g, '-')}`

/**
 * The header's menus (src/components/site-header.tsx builds them). A menu opens on click, or on
 * hover with a pointer that can hover, and closes on Escape (focus returns to its button), when
 * focus or the pointer leaves it, on a click outside, and on any link click. Below 900px the menus
 * fold into one panel behind a menu button.
 */
export function SiteNav({ menus, download }: { menus: readonly NavMenu[]; download: ReactNode }) {
  const [open, setOpen] = useState<string | null>(null)
  const [panel, setPanel] = useState(false)
  const nav = useRef<HTMLElement>(null)
  const burger = useRef<HTMLButtonElement>(null)
  const sheet = useRef<HTMLDivElement>(null)
  const buttons = useRef(new Map<string, HTMLButtonElement>())
  // A menu the pointer just opened stays open when the same pointer then clicks its button.
  const hoverOpened = useRef<string | null>(null)
  const pathname = usePathname()
  // The latest open state, for the document listeners below.
  const state = useRef({ open, panel })
  state.current = { open, panel }

  const closeAll = useCallback(() => {
    setOpen(null)
    setPanel(false)
    hoverOpened.current = null
  }, [])

  // Navigating away (including the Back button) closes everything.
  // biome-ignore lint/correctness/useExhaustiveDependencies: runs on each new pathname.
  useEffect(closeAll, [pathname, closeAll])

  useEffect(() => {
    function onKey(event: KeyboardEvent) {
      if (event.key !== 'Escape') return
      // Focus goes back to the button only if it was inside the nav, so Escape elsewhere on the
      // page doesn't move it.
      const focused = document.activeElement
      const menu = state.current.open
      const menuItem = menu ? buttons.current.get(menu)?.parentElement : null
      if (menu && menuItem?.contains(focused)) buttons.current.get(menu)?.focus()
      else if (state.current.panel && sheet.current?.contains(focused)) burger.current?.focus()
      closeAll()
    }
    function onPointer(event: PointerEvent) {
      const target = event.target as Node
      if (!nav.current?.contains(target)) closeAll()
      // A press on the header between the menus (not on a menu or its button) closes them too.
      else if (!(target instanceof Element && target.closest('.nav-item'))) setOpen(null)
    }
    document.addEventListener('keydown', onKey)
    document.addEventListener('pointerdown', onPointer)
    return () => {
      document.removeEventListener('keydown', onKey)
      document.removeEventListener('pointerdown', onPointer)
    }
  }, [closeAll])

  const canHover = () => window.matchMedia('(hover: hover) and (pointer: fine)').matches

  function leaveFocus(label: string) {
    return (event: FocusEvent<HTMLElement>) => {
      // Only focus that moves to another element counts: a click on blank space, or Safari not
      // focusing a clicked link, leaves relatedTarget null and must not close the menu.
      const next = event.relatedTarget
      if (next instanceof Node && !event.currentTarget.contains(next)) {
        setOpen(current => (current === label ? null : current))
        if (hoverOpened.current === label) hoverOpened.current = null
      }
    }
  }

  return (
    <nav
      ref={nav}
      className="site-nav"
      aria-label="Main"
      onPointerLeave={() => {
        if (canHover()) {
          setOpen(null)
          hoverOpened.current = null
        }
      }}
    >
      <ul className="nav-menus">
        {menus.map(menu =>
          'href' in menu ? (
            <li key={menu.label}>
              <Link
                href={menu.href}
                prefetch={linkPrefetch(menu.href)}
                className="nav-top"
                onClick={closeAll}
              >
                {menu.label}
              </Link>
            </li>
          ) : (
            <li
              key={menu.label}
              className={menu.wide ? 'nav-item nav-item-wide' : 'nav-item'}
              onPointerEnter={() => {
                if (canHover() && open !== menu.label) {
                  setOpen(menu.label)
                  hoverOpened.current = menu.label
                }
              }}
              onBlur={leaveFocus(menu.label)}
            >
              <button
                type="button"
                className="nav-top"
                ref={button => {
                  if (button) buttons.current.set(menu.label, button)
                  else buttons.current.delete(menu.label)
                }}
                aria-expanded={open === menu.label}
                aria-controls={panelId(menu.label)}
                onClick={() => {
                  if (hoverOpened.current === menu.label) {
                    hoverOpened.current = null
                    return
                  }
                  setOpen(open === menu.label ? null : menu.label)
                }}
              >
                {menu.label}
                <span className="nav-chevron" aria-hidden="true" />
              </button>
              <div
                id={panelId(menu.label)}
                className={menu.wide ? 'nav-panel nav-panel-wide' : 'nav-panel'}
                hidden={open !== menu.label}
              >
                <MenuGroups menu={menu} onNavigate={closeAll} />
              </div>
            </li>
          )
        )}
      </ul>
      <div className="nav-actions">
        {download}
        <button
          type="button"
          ref={burger}
          className="nav-burger"
          aria-expanded={panel}
          aria-controls={panel ? 'nav-sheet' : undefined}
          onClick={() => setPanel(!panel)}
        >
          {panel ? <X aria-hidden="true" size={20} /> : <Menu aria-hidden="true" size={20} />}
          <span className="sr-only">Menu</span>
        </button>
      </div>
      {/* Rendered only while open, so the header never carries a second copy of every link. */}
      {panel && (
        <div id="nav-sheet" ref={sheet} className="nav-sheet">
          {menus.map(menu =>
            'href' in menu ? (
              <Link
                key={menu.label}
                href={menu.href}
                prefetch={linkPrefetch(menu.href)}
                className="nav-sheet-top"
                onClick={closeAll}
              >
                {menu.label}
              </Link>
            ) : (
              <div key={menu.label} className="nav-sheet-group">
                <p className="nav-sheet-label">{menu.label}</p>
                <MenuGroups menu={menu} onNavigate={closeAll} />
              </div>
            )
          )}
        </div>
      )}
    </nav>
  )
}

function MenuGroups({
  menu,
  onNavigate
}: {
  menu: Extract<NavMenu, { groups: unknown }>
  onNavigate: () => void
}) {
  return (
    <>
      <div className="nav-groups">
        {menu.groups.map(group => (
          <div key={group.title ?? menu.label} className="nav-group">
            {group.title && <p className="nav-group-title">{group.title}</p>}
            <ul>
              {group.links.map(link => (
                <li key={link.href}>
                  <Link
                    href={link.href}
                    prefetch={linkPrefetch(link.href)}
                    className="nav-link"
                    onClick={onNavigate}
                  >
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
        <Link
          href={menu.more.href}
          prefetch={linkPrefetch(menu.more.href)}
          className="nav-more"
          onClick={onNavigate}
        >
          {menu.more.label} →
        </Link>
      )}
    </>
  )
}
