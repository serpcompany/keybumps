import { PluginPage } from '@/components/plugin-page'
import { pluginMetadata } from '@/lib/metadata'
import { pluginFor } from '@/lib/plugins'

export const metadata = pluginMetadata(pluginFor('quick-search'))

export default function QuickSearchPluginPage() {
  return <PluginPage slug="quick-search" />
}
