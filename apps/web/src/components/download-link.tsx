import type { ReactNode } from 'react'
import { getCurrentRelease } from '@/lib/latest-release'

/**
 * A link that starts the download of the current Keybumps DMG, as named by latest.json (with its
 * validation and fallback, src/lib/latest-release.ts). Download buttons use it instead of linking
 * to /download/, which only redirects to the same file.
 */
export async function DownloadLink({
  className,
  children
}: {
  className?: string
  children: ReactNode
}) {
  const release = await getCurrentRelease()
  return (
    <a href={release.dmgURL} className={className}>
      {children}
    </a>
  )
}
