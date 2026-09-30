import type { ReactNode } from 'react'
import { LEGAL_UPDATED } from '@/lib/site'

/** A text page: legal documents, help pages, and the sitemap. */
export function PageShell({
  title,
  children,
  showUpdated = false
}: {
  title: string
  children: ReactNode
  /** Legal documents show when they last changed; help pages don't. */
  showUpdated?: boolean
}) {
  return (
    <main className="section legal">
      <div className="container narrow">
        <h1>{title}</h1>
        {showUpdated && <p className="fine">Last updated {LEGAL_UPDATED}</p>}
        {children}
      </div>
    </main>
  )
}
