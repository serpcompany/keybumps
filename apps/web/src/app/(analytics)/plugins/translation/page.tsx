import { PluginPage } from '@/components/plugin-page'
import { pluginMetadata } from '@/lib/metadata'
import { pluginFor } from '@/lib/plugins'

export const metadata = pluginMetadata(pluginFor('translation'))

export default function TranslationPluginPage() {
  return <PluginPage slug="translation" />
}
