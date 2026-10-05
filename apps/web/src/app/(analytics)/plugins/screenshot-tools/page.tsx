import { PluginPage } from '@/components/plugin-page'
import { pluginMetadata } from '@/lib/metadata'
import { pluginFor } from '@/lib/plugins'

export const metadata = pluginMetadata(pluginFor('screenshot-tools'))

export default function ScreenshotToolsPluginPage() {
  return <PluginPage slug="screenshot-tools" />
}
