'use client'

import { CalendarDays, Check, ChevronDown, Link2, Search, X } from 'lucide-react'
import { Fragment, type ReactNode, useEffect, useRef, useState } from 'react'
import { PluginIcon } from '@/components/plugin-icon'
import type { NoteBlock, Release } from '@/lib/changelog'
import { absoluteUrl } from '@/lib/site'

/** Inline Markdown in the notes: **bold**, `code`, and [links](…). */
const inlineToken = /(\*\*[^*]+\*\*|`[^`]+`|\[[^\]]+\]\([^)]+\))/

function escapeRegExp(text: string) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

/** Plain text with each search word marked. */
function marked(text: string, words: readonly string[]): ReactNode {
  if (!words.length) return text
  const pattern = new RegExp(`(${words.map(escapeRegExp).join('|')})`, 'gi')
  const parts = text.split(pattern)
  return parts.map((part, index) =>
    index % 2 === 1 ? (
      // biome-ignore lint/suspicious/noArrayIndexKey: the parts of one string never reorder.
      <mark key={index}>{part}</mark>
    ) : (
      part
    )
  )
}

/** A line of the notes, with its inline Markdown drawn and the search words marked. */
function Inline({ text, words }: { text: string; words: readonly string[] }) {
  const parts = text.split(inlineToken)
  return (
    <>
      {parts.map((part, index) => {
        const key = `${index}:${part.length}`
        if (part.startsWith('**') && part.endsWith('**'))
          return <strong key={key}>{marked(part.slice(2, -2), words)}</strong>
        if (part.startsWith('`') && part.endsWith('`'))
          return <code key={key}>{marked(part.slice(1, -1), words)}</code>
        const link = /^\[([^\]]+)\]\(([^)]+)\)$/.exec(part)
        if (link)
          return (
            <a key={key} href={link[2]}>
              {marked(link[1], words)}
            </a>
          )
        return <Fragment key={key}>{marked(part, words)}</Fragment>
      })}
    </>
  )
}

function blockKey(block: NoteBlock): string {
  if (block.kind === 'paragraph') return `p:${block.text.slice(0, 48)}`
  if (block.kind === 'list') return `l:${block.items[0]?.slice(0, 48)}`
  return `c:${block.blocks.map(blockKey).join('|').slice(0, 48)}`
}

function Blocks({ blocks, words }: { blocks: readonly NoteBlock[]; words: readonly string[] }) {
  return (
    <>
      {blocks.map(block => {
        if (block.kind === 'paragraph')
          return (
            <p key={blockKey(block)} className="changelog-paragraph">
              <Inline text={block.text} words={words} />
            </p>
          )
        if (block.kind === 'list')
          return (
            <ul key={blockKey(block)} className="changelog-list">
              {block.items.map(item => (
                <li key={item}>
                  <Inline text={item} words={words} />
                </li>
              ))}
            </ul>
          )
        return (
          <div key={blockKey(block)} className="changelog-callout">
            <Blocks blocks={block.blocks} words={words} />
          </div>
        )
      })}
    </>
  )
}

function sectionText(section: Release['sections'][number]): string {
  const text = (block: NoteBlock): string =>
    block.kind === 'paragraph'
      ? block.text
      : block.kind === 'list'
        ? block.items.join(' ')
        : block.blocks.map(text).join(' ')
  return `${section.heading} ${section.blocks.map(text).join(' ')}`.toLowerCase()
}

/**
 * The client part of /changelog/: one search (versions, dates, and the notes) with a month filter,
 * over the release timeline. The notes are rendered from props the server read at build time.
 * Nothing typed here leaves the page: no URL, storage, or analytics.
 */
export function ChangelogTimeline({ releases }: { releases: readonly Release[] }) {
  const [query, setQuery] = useState('')
  const [month, setMonth] = useState('all')
  const [copied, setCopied] = useState<string | null>(null)
  const search = useRef<HTMLInputElement>(null)

  // ⌘K, or Ctrl-K, focuses the search, as on /plugins/.
  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.key.toLowerCase() !== 'k' || !(event.metaKey || event.ctrlKey)) return
      event.preventDefault()
      search.current?.focus()
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [])

  useEffect(() => {
    if (!copied) return
    const timer = window.setTimeout(() => setCopied(null), 2000)
    return () => window.clearTimeout(timer)
  }, [copied])

  const months = releases.reduce<{ label: string; count: number }[]>((list, release) => {
    const entry = list.find(item => item.label === release.monthLabel)
    if (entry) entry.count++
    else list.push({ label: release.monthLabel, count: 1 })
    return list
  }, [])
  const words = query.toLowerCase().split(/\s+/).filter(Boolean)
  const shown = releases.filter(
    release =>
      (month === 'all' || release.monthLabel === month) &&
      words.every(word => release.searchText.includes(word))
  )
  const filtered = words.length > 0 || month !== 'all'
  const latest = releases[0]?.id

  function clear() {
    setQuery('')
    setMonth('all')
    search.current?.focus()
  }

  async function copyLink(release: Release) {
    const url = absoluteUrl(`/changelog/#${release.id}`)
    try {
      await navigator.clipboard.writeText(url)
      setCopied(release.id)
    } catch {
      // Clipboard refused: put the release in the address bar, where it can be copied.
      window.location.hash = release.id
    }
  }

  return (
    <>
      <search className="changelog-finder">
        <div className="container changelog-finder-inner">
          <div className="changelog-search">
            <Search aria-hidden="true" size={16} />
            <input
              ref={search}
              type="search"
              value={query}
              autoComplete="off"
              spellCheck={false}
              placeholder="Search versions, dates, or changes"
              aria-label="Search releases by version, date, or what changed"
              aria-keyshortcuts="Meta+K Control+K"
              onChange={event => setQuery(event.target.value)}
              onKeyDown={event => {
                if (event.key === 'Escape') setQuery('')
              }}
            />
            {query ? (
              <button
                type="button"
                className="changelog-search-clear"
                aria-label="Clear search"
                onClick={() => {
                  setQuery('')
                  search.current?.focus()
                }}
              >
                <X aria-hidden="true" size={14} />
              </button>
            ) : (
              <span className="hero-search-keys" aria-hidden="true">
                <kbd>⌘</kbd>
                <kbd>K</kbd>
              </span>
            )}
            <label className="changelog-month">
              <CalendarDays aria-hidden="true" size={14} />
              <span className="sr-only">Release month</span>
              <select value={month} onChange={event => setMonth(event.target.value)}>
                <option value="all">All time</option>
                {months.map(item => (
                  <option key={item.label} value={item.label}>
                    {item.label} ({item.count})
                  </option>
                ))}
              </select>
              <ChevronDown aria-hidden="true" size={14} />
            </label>
          </div>
          <p className="changelog-count" aria-live="polite">
            {filtered && (
              <>
                Showing {shown.length} of {releases.length} releases
                <button type="button" onClick={clear}>
                  Clear
                </button>
              </>
            )}
          </p>
        </div>
      </search>

      <div className="container">
        {shown.length === 0 && (
          <div className="changelog-empty">
            <p>
              {words.length
                ? `No release${month === 'all' ? '' : ` in ${month}`} matches “${query.trim()}”. Try a version such as beta.19, a date such as Oct 5, or a plugin's name.`
                : 'No releases in this month.'}
            </p>
            <button type="button" onClick={clear}>
              Show every release
            </button>
          </div>
        )}
        <ol className="changelog-timeline" aria-label="Releases, newest first">
          {shown.map((release, index) => {
            const startsMonth = release.monthLabel !== shown[index - 1]?.monthLabel
            const matching = release.sections.map(section =>
              words.some(word => sectionText(section).includes(word))
            )
            const anyMatch = matching.some(Boolean)
            return (
              <li key={release.id} className="changelog-entry">
                {startsMonth && (
                  <div className="changelog-row changelog-month-row">
                    <h2 className="changelog-month-label">{release.monthLabel}</h2>
                    <div
                      className={
                        index === 0 ? 'changelog-rail changelog-rail-start' : 'changelog-rail'
                      }
                    />
                  </div>
                )}
                <article id={release.id} className="changelog-row changelog-release">
                  <div className="changelog-meta">
                    <div className="changelog-version-row">
                      <a className="changelog-version" href={`#${release.id}`}>
                        {marked(release.version, words)}
                      </a>
                      <button
                        type="button"
                        className="changelog-copy"
                        aria-label={`Copy link to ${release.version}`}
                        title="Copy link"
                        onClick={() => copyLink(release)}
                      >
                        {copied === release.id ? (
                          <Check aria-hidden="true" size={14} />
                        ) : (
                          <Link2 aria-hidden="true" size={14} />
                        )}
                      </button>
                    </div>
                    {release.id === latest && <span className="changelog-latest">Latest</span>}
                    {release.dateLabel && (
                      <time className="changelog-date" dateTime={release.date ?? undefined}>
                        {marked(release.dateLabel, words)}
                      </time>
                    )}
                  </div>
                  <div
                    className={
                      index === shown.length - 1
                        ? 'changelog-rail changelog-rail-end'
                        : 'changelog-rail'
                    }
                  >
                    <span
                      className={
                        release.id === latest
                          ? 'changelog-dot changelog-dot-latest'
                          : 'changelog-dot'
                      }
                    />
                  </div>
                  <div className="changelog-body">
                    <h3>
                      <Inline text={release.summary} words={words} />
                    </h3>
                    {release.plugins.length > 0 && (
                      <div className="changelog-plugins">
                        {release.plugins.map(plugin => (
                          <button
                            key={plugin.slug}
                            type="button"
                            className="changelog-plugin"
                            title={`Show every release that changed ${plugin.name}`}
                            onClick={() => {
                              setQuery(plugin.name)
                              setMonth('all')
                              search.current?.scrollIntoView({
                                block: 'center',
                                behavior: 'smooth'
                              })
                            }}
                          >
                            <PluginIcon
                              systemImage={plugin.systemImage}
                              tint={plugin.tint}
                              size={18}
                            />
                            {plugin.name}
                          </button>
                        ))}
                      </div>
                    )}
                    <Blocks blocks={release.intro} words={words} />
                    {release.sections.length > 0 && (
                      <div className="changelog-sections">
                        {release.sections.map((section, sectionIndex) => (
                          <details
                            key={section.heading}
                            className="changelog-section"
                            open={
                              words.length
                                ? matching[sectionIndex] || (!anyMatch && sectionIndex === 0)
                                : release.id === latest || sectionIndex === 0
                            }
                          >
                            <summary>
                              <span
                                className={
                                  section.kind === 'fix'
                                    ? 'changelog-tag changelog-tag-fix'
                                    : section.kind === 'new'
                                      ? 'changelog-tag changelog-tag-new'
                                      : 'changelog-tag'
                                }
                              >
                                {marked(section.heading, words)}
                              </span>
                              <span className="changelog-changes">
                                {section.changes} {section.changes === 1 ? 'change' : 'changes'}
                              </span>
                              <ChevronDown
                                aria-hidden="true"
                                size={16}
                                className="changelog-chevron"
                              />
                            </summary>
                            <Blocks blocks={section.blocks} words={words} />
                          </details>
                        ))}
                      </div>
                    )}
                  </div>
                </article>
              </li>
            )
          })}
        </ol>
        <p className="sr-only" aria-live="polite">
          {copied ? 'Link copied' : ''}
        </p>
      </div>
    </>
  )
}
