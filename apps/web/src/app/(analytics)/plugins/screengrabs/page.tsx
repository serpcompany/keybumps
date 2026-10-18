import { PluginPage } from '@/components/plugin-page'
import { pluginMetadata } from '@/lib/metadata'
import { pluginFor } from '@/lib/plugins'

export const metadata = pluginMetadata(pluginFor('screengrabs'))

export default function ScreenGrabsPluginPage() {
  return <PluginPage slug="screengrabs" />
}
