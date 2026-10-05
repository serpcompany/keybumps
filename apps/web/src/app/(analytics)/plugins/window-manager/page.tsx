import { PluginPage } from '@/components/plugin-page'
import { pluginMetadata } from '@/lib/metadata'
import { pluginFor } from '@/lib/plugins'

export const metadata = pluginMetadata(pluginFor('window-manager'))

export default function WindowManagerPluginPage() {
  return <PluginPage slug="window-manager" />
}
