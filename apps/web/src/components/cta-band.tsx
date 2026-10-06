import type { ReactNode } from 'react'

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
        <p>{children ?? 'Apple silicon · macOS 14.2 or later'}</p>
      </div>
      {action}
    </div>
  )
}
