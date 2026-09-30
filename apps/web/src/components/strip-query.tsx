'use client'

import { useEffect } from 'react'

/** The URL without its query string. Exported for tests. */
export function strippedUrl(location: Pick<Location, 'pathname' | 'hash'>) {
  return location.pathname + location.hash
}

/**
 * Replaces the current history entry's URL with `url` while keeping the Next.js router's state.
 * Once the App Router has patched `history.replaceState` (it does so in an effect of its own),
 * a call without Next.js state goes through the router: it copies the router's history state into
 * the entry and updates the router's URL. Before that, the native method would drop the router's
 * state (and Back into the page would stop rendering it), so the existing state is passed on.
 */
export function replaceUrlKeepingRouterState(history: History, url: string) {
  const patchedByRouter = history.replaceState !== History.prototype.replaceState
  history.replaceState(patchedByRouter ? null : history.state, '', url)
}

/**
 * Removes the query string from the address bar and the current history entry once the page has
 * rendered. The (no-analytics) root layout mounts it: those pages' URLs can carry checkout,
 * session, or license data (Polar appends them to /thanks/), and nothing on them reads the query.
 * This is a second layer; those pages never load analytics.
 */
export function StripQuery() {
  useEffect(() => {
    if (!window.location.search) return
    // Wait for the rest of this commit's effects, including the App Router's history patch.
    const timer = window.setTimeout(() => {
      if (window.location.search) {
        replaceUrlKeepingRouterState(window.history, strippedUrl(window.location))
      }
    }, 0)
    return () => window.clearTimeout(timer)
  }, [])
  return null
}
