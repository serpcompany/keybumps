import { PageShell } from '@/components/page-shell'
import { pageMetadata } from '@/lib/metadata'

export const metadata = pageMetadata('/about/')

export default function AboutPage() {
  return (
    <PageShell title="About">
      <p>
        Keybumps is a native macOS app from SERP. It brings quick search, clipboard history,
        screenshots, dictation, window management, and shortcut coaching into one keyboard-first
        app, and it runs on your Mac with no account.
      </p>
    </PageShell>
  )
}
