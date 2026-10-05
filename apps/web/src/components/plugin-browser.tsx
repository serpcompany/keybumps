'use client'

import { Search } from 'lucide-react'
import { type ReactNode, useEffect, useId, useRef, useState } from 'react'

export type PluginBrowserEntry = {
  slug: string
  /** Its category in lowercase, matching a filter's value. */
  category: string
  isNew: boolean
  /** What the search matches, in lowercase (`searchTerms()` in src/lib/plugins.ts). */
  terms: string
  /** The server-rendered card. */
  card: ReactNode
}

export type PluginFilter = { value: string; label: string }

/**
 * The client part of /plugins/: the search under the title and the filter tabs, which together
 * show or hide the server-rendered cards as you type or pick. Everything else on the page is
 * rendered on the server and passed in. Nothing typed here leaves the page: no URL, storage, or
 * analytics.
 */
export function PluginBrowser({
  hero,
  filters,
  entries,
  heading,
  subtitle
}: {
  hero: ReactNode
  filters: readonly PluginFilter[]
  entries: readonly PluginBrowserEntry[]
  heading: string
  subtitle: string
}) {
  const [query, setQuery] = useState('')
  const [filter, setFilter] = useState(filters[0]?.value ?? 'all')
  const search = useRef<HTMLInputElement>(null)
  const list = useRef<HTMLElement>(null)
  const headingId = useId()

  // ⌘K, or Ctrl-K, focuses the search.
  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.key.toLowerCase() !== 'k' || !(event.metaKey || event.ctrlKey)) return
      event.preventDefault()
      search.current?.scrollIntoView({ block: 'center', behavior: 'smooth' })
      search.current?.focus({ preventScroll: true })
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [])

  const words = query.toLowerCase().split(/\s+/).filter(Boolean)
  const shows = (entry: PluginBrowserEntry) =>
    (filter === 'all' || (filter === 'new' ? entry.isNew : entry.category === filter)) &&
    words.every(word => entry.terms.includes(word))
  const shown = entries.filter(shows).length

  return (
    <>
      <section className="plugins-hero">
        <div className="plugins-wrap plugins-hero-inner">
          {hero}
          <search className="hero-search-wrap">
            <form
              className="hero-search"
              onSubmit={event => {
                event.preventDefault()
                list.current?.scrollIntoView({ behavior: 'smooth' })
              }}
            >
              <Search aria-hidden="true" size={16} />
              <input
                ref={search}
                type="search"
                value={query}
                autoComplete="off"
                spellCheck={false}
                placeholder="Search plugins…"
                aria-label="Search plugins"
                aria-controls={headingId}
                aria-keyshortcuts="Meta+K Control+K"
                onChange={event => setQuery(event.target.value)}
                onKeyDown={event => {
                  if (event.key === 'Escape') setQuery('')
                }}
              />
              <span className="hero-search-keys" aria-hidden="true">
                <kbd>⌘</kbd>
                <kbd>K</kbd>
              </span>
            </form>
          </search>
          <fieldset className="filter-tabs">
            <legend className="sr-only">Show</legend>
            {filters.map(option => (
              <button
                key={option.value}
                type="button"
                aria-pressed={filter === option.value}
                onClick={() => setFilter(option.value)}
              >
                {option.label}
              </button>
            ))}
          </fieldset>
        </div>
      </section>

      <section ref={list} className="plugins-all" aria-labelledby={headingId}>
        <div className="plugins-wrap">
          <header className="plugins-section-head">
            <h2 id={headingId}>{heading}</h2>
            <p>{subtitle}</p>
          </header>

          <ul className="plugin-list">
            {entries.map(entry => (
              <li key={entry.slug} className="plugin-list-item" hidden={!shows(entry)}>
                {entry.card}
              </li>
            ))}
          </ul>
          {shown === 0 && <p className="plugin-list-empty">No plugins match your search.</p>}
          <p className="sr-only" aria-live="polite">
            {shown === entries.length ? '' : `${shown} of ${entries.length} plugins shown`}
          </p>
        </div>
      </section>
    </>
  )
}
