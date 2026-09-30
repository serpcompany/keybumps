import type { Metadata } from 'next'
import { PageShell } from '@/components/page-shell'
import { getLatestRelease } from '@/lib/latest-release'

export const metadata: Metadata = {
  title: { absolute: 'Download Keybumps' },
  description: 'Download the latest Keybumps beta for macOS.',
  alternates: { canonical: '/download/' },
  robots: { index: false, follow: false }
}

// Re-read the release pointer at most every five minutes.
export const revalidate = 300

export default async function DownloadPage() {
  const release = await getLatestRelease()
  return (
    <PageShell title="Download Keybumps">
      <p>Latest beta: {release.version}</p>
      <p>
        <a href={release.dmgURL} className="btn">
          Download Keybumps for macOS
        </a>
      </p>
    </PageShell>
  )
}
