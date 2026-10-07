'use client'

import { useEffect, useState } from 'react'

type Row = { icon: string; title: string; meta: string }
/** A footer hint, as the app's footer names a tab's actions: Return's first, then the others. */
type Hint = { keys: string; title: string }
type Tab = { key: string; label: string; query: string; rows: Row[]; footer: Hint[] }

const COPY: Hint = { keys: '↵', title: 'Copy' }
const PASTE: Hint = { keys: '⌘P', title: 'Paste' }

const TABS: Tab[] = [
  {
    key: '⌘1',
    label: 'Search',
    query: 'figma',
    rows: [
      { icon: '◆', title: 'Figma', meta: 'Application' },
      { icon: '▤', title: 'figma-export-final.pdf', meta: '~/Downloads' },
      { icon: '▢', title: 'Figma Assets', meta: '~/Design' },
      { icon: '▤', title: 'figma-tokens.json', meta: '~/dev/site' }
    ],
    footer: [{ keys: '↵', title: 'Open' }]
  },
  {
    key: '⌘2',
    label: 'Clipboard',
    query: 'invoice',
    rows: [
      { icon: '¶', title: 'Invoice #2041 — due Oct 12', meta: '2m ago' },
      { icon: '▣', title: 'invoice-screenshot.png', meta: 'Image · 14m ago' },
      { icon: '¶', title: 'billing@acme.co', meta: '1h ago' },
      { icon: '¶', title: 'Net 30, paid via ACH', meta: 'Yesterday' }
    ],
    footer: [COPY, PASTE]
  },
  {
    key: '⌘3',
    label: 'Screenshots',
    query: '',
    rows: [
      { icon: '▣', title: 'Screenshot 9:41:02', meta: 'Area · ⌘Return to edit' },
      { icon: '▣', title: 'Screenshot 9:38:47', meta: 'All screens' },
      { icon: '▣', title: 'Screenshot 9:12:10', meta: 'Edited · redacted' }
    ],
    footer: [COPY, PASTE, { keys: '⌘↵', title: 'Edit' }]
  },
  {
    key: '⌘4',
    label: 'Dictation',
    query: 'standup',
    rows: [
      {
        icon: '◉',
        title: 'Standup: shipped the palette, next up is…',
        meta: '0:42'
      },
      {
        icon: '◉',
        title: 'Reply to Sam about the standup notes',
        meta: '0:18'
      },
      { icon: '◉', title: 'Standup follow-ups for Friday', meta: '1:05' }
    ],
    footer: [COPY, PASTE]
  }
]

export function PaletteDemo() {
  const [tab, setTab] = useState(0)
  const [typed, setTyped] = useState(0)
  const [selected, setSelected] = useState(0)
  // Once someone picks a tab, the demo stops cycling and stays on their choice.
  const [picked, setPicked] = useState(false)
  const current = TABS[tab]

  function pick(index: number) {
    setPicked(true)
    setTab(index)
    setTyped(0)
    setSelected(0)
  }

  useEffect(() => {
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
      setTyped(current.query.length)
      return
    }
    if (typed < current.query.length) {
      const id = setTimeout(() => setTyped(n => n + 1), 110)
      return () => clearTimeout(id)
    }
    if (picked) return
    if (selected < 2) {
      const id = setTimeout(() => setSelected(n => n + 1), 650)
      return () => clearTimeout(id)
    }
    const id = setTimeout(() => {
      setTab(t => (t + 1) % TABS.length)
      setTyped(0)
      setSelected(0)
    }, 1400)
    return () => clearTimeout(id)
  }, [current, typed, selected, picked])

  return (
    <div className="palette">
      <div className="palette-search" aria-hidden="true">
        <span className="palette-glass">⌕</span>
        <span>
          {current.query.slice(0, typed)}
          <span className="caret" />
        </span>
        {!current.query && <span className="palette-placeholder">Recent screenshots</span>}
      </div>
      <div className="palette-tabs">
        {TABS.map((t, i) => (
          <button
            type="button"
            key={t.key}
            className={i === tab ? 'active' : undefined}
            aria-pressed={i === tab}
            onClick={() => pick(i)}
          >
            {t.label} <kbd>{t.key}</kbd>
          </button>
        ))}
      </div>
      <ul className="palette-rows" key={tab} aria-hidden="true">
        {current.rows.map((row, i) => (
          <li key={row.title} className={i === selected ? 'selected' : undefined}>
            <span className="row-icon">{row.icon}</span>
            <span className="row-title">{row.title}</span>
            <span className="row-meta">{row.meta}</span>
          </li>
        ))}
      </ul>
      <div className="palette-footer" aria-hidden="true">
        {current.footer.map(hint => (
          <span key={hint.title}>
            <kbd>{hint.keys}</kbd> {hint.title}
          </span>
        ))}
      </div>
    </div>
  )
}
