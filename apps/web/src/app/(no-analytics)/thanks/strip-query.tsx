'use client'

import { useEffect } from 'react'

/**
 * Removes the checkout and customer-session parameters Polar appends to /thanks/ from the address
 * bar and the history entry, once the page has rendered. Nothing on the page reads them. This is
 * a second layer: the page's root layout already never loads analytics.
 */
export function StripQuery() {
  useEffect(() => {
    if (!window.location.search) return
    window.history.replaceState(null, '', window.location.pathname + window.location.hash)
  }, [])
  return null
}
