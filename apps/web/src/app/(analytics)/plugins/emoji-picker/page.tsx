import { PluginPage } from '@/components/plugin-page'
import { pluginMetadata } from '@/lib/metadata'
import { pluginFor } from '@/lib/plugins'

export const metadata = pluginMetadata(pluginFor('emoji-picker'))

export default function EmojiPickerPluginPage() {
  return <PluginPage slug="emoji-picker" />
}
