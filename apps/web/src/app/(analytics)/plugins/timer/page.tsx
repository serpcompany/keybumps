import { PluginPage } from '@/components/plugin-page'
import { pluginMetadata } from '@/lib/metadata'
import { pluginFor } from '@/lib/plugins'

export const metadata = pluginMetadata(pluginFor('timer'))

export default function TimerPluginPage() {
  return <PluginPage slug="timer" />
}
