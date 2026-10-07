import type { ReactNode } from 'react'
import { MINIMUM_MACOS } from '@/lib/site'

/**
 * The closing call to action at the bottom of a page: a headline and the Download button. The page
 * passes the button in (`<DownloadLink className="btn btn-lg">`), because it reads latest.json.
 */
export function CtaBand({
  title,
  action,
  children
}: {
  title: string
  action: ReactNode
  children?: ReactNode
}) {
  return (
    <div className="cta-band">
      <div>
        <h2>{title}</h2>
        <p>{children ?? `Apple silicon · macOS ${MINIMUM_MACOS} or later`}</p>
      </div>
      {action}
    </div>
  )
}
