import { PluginPage } from '@/components/plugin-page'
import { pluginMetadata } from '@/lib/metadata'
import { pluginFor } from '@/lib/plugins'

export const metadata = pluginMetadata(pluginFor('clipboard-history'))

export default function ClipboardHistoryPluginPage() {
  return <PluginPage slug="clipboard-history" />
}
