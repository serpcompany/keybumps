'use client'

import { useEffect, useState } from 'react'
import { type ConsentChoice, consentEvent, consentStorageKey, storedConsent } from '@/lib/consent'

/**
 * The cookie choice for visitors who need one (`lib/consent.ts`): shown until they accept or
 * decline, and never again on this browser after. The analytics component renders it, in production only.
 */
export function ConsentBanner() {
  const [shown, setShown] = useState(false)

  useEffect(() => {
    let stored: ConsentChoice | null = null
    try {
      stored = storedConsent(localStorage.getItem(consentStorageKey))
    } catch {
      // Storage blocked: ask, and the choice lasts this page.
    }
    if (stored) return
    let cancelled = false
    fetch('/api/consent/', { cache: 'no-store' })
      .then(response => (response.ok ? response.json() : null))
      .then(body => {
        if (!cancelled && body?.required === true) setShown(true)
      })
      .catch(() => {})
    return () => {
      cancelled = true
    }
  }, [])

  if (!shown) return null

  function choose(choice: ConsentChoice) {
    try {
      localStorage.setItem(consentStorageKey, choice)
    } catch {
      // Storage blocked: the choice still applies to this page.
    }
    window.dispatchEvent(new CustomEvent(consentEvent, { detail: choice }))
    setShown(false)
  }

  return (
    <section className="consent-banner" aria-label="Cookie choice">
      <p>
        We use cookies to count visits and to measure the ads that bring people here.{' '}
        <a href="/legal/privacy/">Privacy policy</a>
      </p>
      <div className="consent-actions">
        <button type="button" className="btn btn-sm" onClick={() => choose('granted')}>
          Accept
        </button>
        <button type="button" className="btn btn-sm btn-ghost" onClick={() => choose('denied')}>
          Decline
        </button>
      </div>
    </section>
  )
}
