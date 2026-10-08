import { ChangelogTimeline } from '@/components/changelog-timeline'
import sources from '@/generated/changelog-sources.json'
import { releasesFrom } from '@/lib/changelog'
import { pageMetadata } from '@/lib/metadata'

export const metadata = pageMetadata('/changelog/')

export default function ChangelogPage() {
  return (
    <main className="changelog">
      <section className="changelog-hero">
        <div className="container">
          <h1>Changelog</h1>
        </div>
      </section>
      <ChangelogTimeline releases={releasesFrom(sources.notes, sources.changelog)} />
    </main>
  )
}
