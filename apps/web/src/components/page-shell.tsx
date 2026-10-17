import type { ReactNode } from 'react'
import { LEGAL_UPDATED } from '@/lib/site'

/** A text page: legal documents, help pages, and the sitemap. */
export function PageShell({
  title,
  children,
  showUpdated = false,
  updated = LEGAL_UPDATED
}: {
  title: string
  children: ReactNode
  /** Legal documents show when they last changed; help pages don't. */
  showUpdated?: boolean
  /** When this document last changed, if not with the other legal pages. */
  updated?: string
}) {
  return (
    <main className="section legal">
      <div className="container narrow">
        <h1>{title}</h1>
        {showUpdated && <p className="fine">Last updated {updated}</p>}
        {children}
      </div>
    </main>
  )
}
