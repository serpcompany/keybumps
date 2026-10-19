import { ChangelogTimeline } from '@/components/changelog-timeline'
import sources from '@/generated/changelog-sources.json'
import releaseIndex from '@/generated/release-index.json'
import { releasesFrom } from '@/lib/changelog'
import { getCurrentRelease } from '@/lib/latest-release'
import { pageMetadata } from '@/lib/metadata'
import { releaseDownloads } from '@/lib/release-downloads'

export const metadata = pageMetadata('/changelog/')

export default async function ChangelogPage() {
  const releases = releasesFrom(sources.notes, sources.changelog)
  const downloads = releaseDownloads(
    releases.map(release => release.version),
    releaseIndex,
    await getCurrentRelease()
  )
  return (
    <main className="changelog">
      <section className="changelog-hero">
        <div className="container">
          <h1>Changelog</h1>
        </div>
      </section>
      <ChangelogTimeline releases={releases} downloads={downloads} />
    </main>
  )
}
