import {
  AudioWaveform,
  Clipboard,
  Columns2,
  Focus,
  Keyboard,
  type LucideIcon,
  Search,
  TextQuote,
  Timer
} from 'lucide-react'
import type { CSSProperties } from 'react'
import { type IconTint, iconTints, type PluginSystemImage } from '@/lib/plugins'

/** Web stand-ins, from the site's icon library (lucide), for the SF Symbols the app draws. */
const icons: Record<PluginSystemImage, LucideIcon> = {
  magnifyingglass: Search,
  clipboard: Clipboard,
  'camera.viewfinder': Focus,
  waveform: AudioWaveform,
  'rectangle.split.2x1': Columns2,
  keyboard: Keyboard,
  'text.quote': TextQuote,
  timer: Timer
}

/**
 * A plugin's icon as the app's Settings draws it (`SettingsIconTile`): a white symbol on a rounded
 * square filled with its tint.
 */
export function PluginIcon({
  systemImage,
  tint
}: {
  systemImage: PluginSystemImage
  tint: IconTint
}) {
  const Icon = icons[systemImage]
  return (
    <span className="plugin-icon" style={{ '--tint': iconTints[tint] } as CSSProperties}>
      <Icon aria-hidden="true" size={22} strokeWidth={2.25} />
    </span>
  )
}
