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
 * square filled with its tint. `size` is the tile's width in pixels; the symbol and the corner
 * radius scale with it.
 */
export function PluginIcon({
  systemImage,
  tint,
  size = 44,
  className
}: {
  systemImage: PluginSystemImage
  tint: IconTint
  size?: number
  className?: string
}) {
  const Icon = icons[systemImage]
  const style = { '--tint': iconTints[tint], '--size': `${size}px` } as CSSProperties
  return (
    <span className={className ? `plugin-icon ${className}` : 'plugin-icon'} style={style}>
      <Icon aria-hidden="true" size={Math.round(size * 0.5)} strokeWidth={size < 32 ? 2.5 : 2.25} />
    </span>
  )
}
