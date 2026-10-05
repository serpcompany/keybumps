import { PluginPage } from '@/components/plugin-page'
import { pluginMetadata } from '@/lib/metadata'
import { pluginFor } from '@/lib/plugins'

export const metadata = pluginMetadata(pluginFor('dictation'))

export default function DictationPluginPage() {
  return <PluginPage slug="dictation" />
}
