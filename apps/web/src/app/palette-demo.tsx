'use client';

import { useEffect, useState } from 'react';

type Row = { icon: string; title: string; meta: string };
type Tab = { key: string; label: string; query: string; rows: Row[] };

const TABS: Tab[] = [
  {
    key: '⌘1',
    label: 'Search',
    query: 'figma',
    rows: [
      { icon: '◆', title: 'Figma', meta: 'Application' },
      { icon: '▤', title: 'figma-export-final.pdf', meta: '~/Downloads' },
      { icon: '▢', title: 'Figma Assets', meta: '~/Design' },
      { icon: '▤', title: 'figma-tokens.json', meta: '~/dev/site' },
    ],
  },
  {
    key: '⌘2',
    label: 'Clipboard',
    query: 'invoice',
    rows: [
      { icon: '¶', title: 'Invoice #2041 — due Oct 12', meta: '2m ago' },
      { icon: '▣', title: 'invoice-screenshot.png', meta: 'Image · 14m ago' },
      { icon: '¶', title: 'billing@acme.co', meta: '1h ago' },
      { icon: '¶', title: 'Net 30, paid via ACH', meta: 'Yesterday' },
    ],
  },
  {
    key: '⌘3',
    label: 'Screenshots',
    query: '',
    rows: [
      { icon: '▣', title: 'Screenshot 9:41:02', meta: 'Area · Return to edit' },
      { icon: '▣', title: 'Screenshot 9:38:47', meta: 'All screens' },
      { icon: '▣', title: 'Screenshot 9:12:10', meta: 'Edited · redacted' },
    ],
  },
  {
    key: '⌘4',
    label: 'Dictation',
    query: 'standup',
    rows: [
      {
        icon: '◉',
        title: 'Standup: shipped the palette, next up is…',
        meta: '0:42',
      },
      {
        icon: '◉',
        title: 'Reply to Sam about the standup notes',
        meta: '0:18',
      },
      { icon: '◉', title: 'Standup follow-ups for Friday', meta: '1:05' },
    ],
  },
];

export function PaletteDemo() {
  const [tab, setTab] = useState(0);
  const [typed, setTyped] = useState(0);
  const [selected, setSelected] = useState(0);
  const current = TABS[tab];

  useEffect(() => {
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
      setTyped(current.query.length);
      return;
    }
    if (typed < current.query.length) {
      const id = setTimeout(() => setTyped((n) => n + 1), 110);
      return () => clearTimeout(id);
    }
    if (selected < 2) {
      const id = setTimeout(() => setSelected((n) => n + 1), 650);
      return () => clearTimeout(id);
    }
    const id = setTimeout(() => {
      setTab((t) => (t + 1) % TABS.length);
      setTyped(0);
      setSelected(0);
    }, 1400);
    return () => clearTimeout(id);
  }, [current, typed, selected]);

  return (
    <div className="palette" aria-hidden="true">
      <div className="palette-search">
        <span className="palette-glass">⌕</span>
        <span>
          {current.query.slice(0, typed)}
          <span className="caret" />
        </span>
        {!current.query && (
          <span className="palette-placeholder">Recent screenshots</span>
        )}
      </div>
      <div className="palette-tabs">
        {TABS.map((t, i) => (
          <span key={t.key} className={i === tab ? 'active' : undefined}>
            {t.label} <kbd>{t.key}</kbd>
          </span>
        ))}
      </div>
      <ul className="palette-rows" key={tab}>
        {current.rows.map((row, i) => (
          <li
            key={row.title}
            className={i === selected ? 'selected' : undefined}
          >
            <span className="row-icon">{row.icon}</span>
            <span className="row-title">{row.title}</span>
            <span className="row-meta">{row.meta}</span>
          </li>
        ))}
      </ul>
      <div className="palette-footer">
        <span>
          <kbd>↵</kbd> Open
        </span>
        <span>
          <kbd>⌘C</kbd> Copy
        </span>
        <span>
          <kbd>⌫</kbd> Delete
        </span>
      </div>
    </div>
  );
}
