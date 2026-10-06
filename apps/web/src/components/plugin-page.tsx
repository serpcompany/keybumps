import { DownloadLink } from '@/components/download-link'
import { PluginDetail } from '@/components/plugin-detail'
import { pluginFor } from '@/lib/plugins'

/**
 * A plugin's page, /plugins/<slug>/, with the Download button for the current DMG. Each plugin
 * has its own static route, src/app/(analytics)/plugins/<slug>/page.tsx, so a slug with no plugin
 * is an unmatched URL and gets the global 404 (src/lib/plugins.test.ts keeps the two in step).
 */
export function PluginPage({ slug }: { slug: string }) {
  return (
    <PluginDetail
      plugin={pluginFor(slug)}
      download={<DownloadLink className="btn">Download Keybumps</DownloadLink>}
      closingDownload={<DownloadLink className="btn btn-lg">Download for macOS</DownloadLink>}
    />
  )
}
