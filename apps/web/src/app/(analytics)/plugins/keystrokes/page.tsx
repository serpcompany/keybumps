import { PluginPage } from '@/components/plugin-page'
import { pluginMetadata } from '@/lib/metadata'
import { pluginFor } from '@/lib/plugins'

export const metadata = pluginMetadata(pluginFor('keystrokes'))

export default function KeystrokesPluginPage() {
  return <PluginPage slug="keystrokes" />
}
