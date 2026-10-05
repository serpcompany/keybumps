import { PluginPage } from '@/components/plugin-page'
import { pluginMetadata } from '@/lib/metadata'
import { pluginFor } from '@/lib/plugins'

export const metadata = pluginMetadata(pluginFor('shortcut-coach'))

export default function ShortcutCoachPluginPage() {
  return <PluginPage slug="shortcut-coach" />
}
