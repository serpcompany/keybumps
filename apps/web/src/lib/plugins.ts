/**
 * The Store's plugins (/plugins/): every plugin in the Mac app, from its plugin manifest. The
 * Swift is the source of truth; copy its wording, and update this when a plugin changes there
 * (ADR 0006: a new plugin's PR or release also adds it to the website).
 *
 * - `apps/macos/Keybumps/Capabilities/*Module.swift`: each `CapabilityDescriptor`'s title,
 *   Settings page summary, category, `systemImage`, `iconTint`, palette tab, required
 *   permissions, and dependencies. Snippets' optional permissions are in `SnippetsModule.swift`.
 * - `apps/macos/Keybumps/Capabilities/PluginManifest.swift`: `PluginCategory`, and the publisher
 *   (every plugin is official, by Keybumps).
 * - `apps/macos/Keybumps/Infrastructure/GlobalShortcutCoordinator.swift`: the `CapabilityShortcut`
 *   titles and default bindings.
 * - `apps/macos/Keybumps/Capabilities/CapabilityModule.swift`: `CapabilityCatalog.descriptors`
 *   (the order) and `CapabilityCatalog.defaultCapabilities`.
 * - `apps/macos/Keybumps/WindowManagement/WindowAction.swift`: Window Manager's own default
 *   window shortcuts, which aren't `CapabilityShortcut`s.
 * - `apps/macos/Keybumps/Infrastructure/SystemServices.swift`: the `MacPermission` titles.
 */

/** `PluginCategory`: where a plugin is listed in the Store. */
export const pluginCategories = ['Productivity', 'Writing', 'Media'] as const
export type PluginCategory = (typeof pluginCategories)[number]

/** `MacPermission` titles, in the app's order. */
export const macPermissions = [
  'Accessibility',
  'Input Monitoring',
  'Microphone',
  'Speech Recognition',
  'Screen Recording'
] as const
export type MacPermission = (typeof macPermissions)[number]

/**
 * The SwiftUI system colors the descriptors use as `iconTint`, as macOS draws them in its dark
 * appearance (the site has one dark theme).
 */
export const iconTints = {
  red: '#ff453a',
  orange: '#ff9f0a',
  purple: '#bf5af2',
  blue: '#0a84ff',
  teal: '#6ac4dc',
  gray: '#98989d',
  green: '#32d74b'
} as const
export type IconTint = keyof typeof iconTints

/** The SF Symbols the plugins use; `src/components/plugin-icon.tsx` maps each to a web icon. */
export type PluginSystemImage =
  | 'magnifyingglass'
  | 'clipboard'
  | 'camera.viewfinder'
  | 'waveform'
  | 'rectangle.split.2x1'
  | 'keyboard'
  | 'text.quote'
  | 'timer'

export type PluginShortcut = {
  title: string
  /** The default binding as the app shows it, or null when it starts unassigned. */
  keys: string | null
}

export type Plugin = {
  /** The plugin's id on the page (`/plugins/#timer`). */
  slug: string
  /** The `Capability` raw value in the app. */
  capability: string
  name: string
  /** The one line under its name on its Settings page and in Settings › Plugins. */
  summary: string
  category: PluginCategory
  /** The SF Symbol the app draws. */
  systemImage: PluginSystemImage
  tint: IconTint
  /** Its Command Palette tab and the Command-number that selects it, if it has one. */
  paletteTab: {
    name: string
    commandKey: number
    /** The tab is hidden until a setting on the plugin's page shows it. */
    hiddenUnless?: string
  } | null
  shortcuts: readonly PluginShortcut[]
  /** Default shortcuts not listed in `shortcuts`. */
  moreShortcuts?: number
  /** macOS permissions it needs while it's on. */
  permissions: readonly MacPermission[]
  /** Permissions it can use without needing them, and what for. */
  optionalPermissions?: string
  /** Slugs of the plugins it needs turned on. */
  requires: readonly string[]
  /** One of the default capabilities, the set Keybumps's features were locked at. */
  isDefault: boolean
  /** The newest added capability, marked New in the Store. */
  isNew?: boolean
}

/** Every plugin, in `CapabilityCatalog.descriptors` order. */
export const plugins: readonly Plugin[] = [
  {
    slug: 'quick-search',
    capability: 'quickSearch',
    name: 'Quick Search',
    summary: 'Open apps, files, and folders from the keyboard.',
    category: 'Productivity',
    systemImage: 'magnifyingglass',
    tint: 'red',
    paletteTab: { name: 'Search', commandKey: 1 },
    shortcuts: [{ title: 'Open Quick Search', keys: '⌘ Space' }],
    permissions: [],
    requires: [],
    isDefault: true
  },
  {
    slug: 'clipboard-history',
    capability: 'clipboardHistory',
    name: 'Clipboard History',
    summary: 'Search text and images you copied earlier and paste them again.',
    category: 'Productivity',
    systemImage: 'clipboard',
    tint: 'orange',
    paletteTab: { name: 'Clipboard', commandKey: 2 },
    shortcuts: [{ title: 'Open Clipboard History', keys: '⇧⌘ Space' }],
    permissions: [],
    requires: [],
    isDefault: true
  },
  {
    slug: 'screenshot-tools',
    capability: 'screenshotTools',
    name: 'Screenshot Tools',
    summary: 'Take screenshots, keep them in Clipboard History, and mark them up.',
    category: 'Media',
    systemImage: 'camera.viewfinder',
    tint: 'purple',
    paletteTab: { name: 'Screenshots', commandKey: 3 },
    shortcuts: [
      { title: 'Screenshot Screen', keys: '⇧⌘2' },
      { title: 'Screenshot Screen and Edit', keys: '⇧⌘3' },
      { title: 'Screenshot Area', keys: '⇧⌘4' }
    ],
    permissions: ['Screen Recording'],
    requires: ['clipboard-history'],
    isDefault: true
  },
  {
    slug: 'dictation',
    capability: 'dictation',
    name: 'Dictation',
    summary: 'Speech to text anywhere, transcribed on this Mac.',
    category: 'Writing',
    systemImage: 'waveform',
    tint: 'blue',
    paletteTab: { name: 'Dictation', commandKey: 4 },
    shortcuts: [{ title: 'Start or stop Dictation', keys: '⌥ Space' }],
    permissions: ['Accessibility', 'Microphone', 'Speech Recognition'],
    requires: [],
    isDefault: true
  },
  {
    slug: 'window-manager',
    capability: 'windowManagement',
    name: 'Window Manager',
    summary: 'Move and resize your application windows.',
    category: 'Productivity',
    systemImage: 'rectangle.split.2x1',
    tint: 'teal',
    paletteTab: null,
    shortcuts: [
      { title: 'Left', keys: '⌃⌥⌘←' },
      { title: 'Right', keys: '⌃⌥⌘→' },
      { title: 'Maximize', keys: '⌃⌥⌘↑' }
    ],
    // WindowAction has 30 actions, and all but Top Right start with a shortcut.
    moreShortcuts: 26,
    permissions: ['Accessibility'],
    requires: [],
    isDefault: true
  },
  {
    slug: 'shortcut-coach',
    capability: 'keyboardShortcutter',
    name: 'Shortcut Coach',
    summary: 'Learn the shortcuts for actions you do by hand.',
    category: 'Productivity',
    systemImage: 'keyboard',
    tint: 'gray',
    paletteTab: {
      name: 'Hotkeys',
      commandKey: 7,
      hiddenUnless: 'Show Hotkeys tab in the Command Palette'
    },
    shortcuts: [],
    permissions: ['Accessibility', 'Input Monitoring'],
    requires: [],
    isDefault: true
  },
  {
    slug: 'snippets',
    capability: 'snippets',
    name: 'Snippets',
    summary: 'Save text you reuse, then copy or paste it from the Command Palette.',
    category: 'Writing',
    systemImage: 'text.quote',
    tint: 'green',
    paletteTab: { name: 'Snippets', commandKey: 5 },
    shortcuts: [{ title: 'Open Snippets', keys: null }],
    permissions: [],
    optionalPermissions:
      'Accessibility to paste into the app you’re using, and Accessibility and Input Monitoring to expand keywords as you type, which is off until you turn it on.',
    requires: [],
    isDefault: true
  },
  {
    slug: 'timer',
    capability: 'timer',
    name: 'Timer',
    summary: 'Count down from a duration and get told when it ends.',
    category: 'Productivity',
    systemImage: 'timer',
    tint: 'orange',
    paletteTab: { name: 'Timers', commandKey: 6 },
    shortcuts: [{ title: 'Open Timers', keys: null }],
    permissions: [],
    requires: [],
    isDefault: false,
    isNew: true
  }
]

export function pluginFor(slug: string): Plugin {
  const plugin = plugins.find(candidate => candidate.slug === slug)
  if (!plugin) throw new Error(`Unknown plugin: ${slug}`)
  return plugin
}

/** The plugins in a category. */
export function pluginsIn(category: PluginCategory): Plugin[] {
  return plugins.filter(plugin => plugin.category === category)
}

/**
 * Permission titles as one phrase, as the app's `MacPermission.names` writes them:
 * "Accessibility", "Microphone and Speech Recognition", or "Accessibility, Microphone, and Speech
 * Recognition".
 */
export function permissionNames(permissions: readonly MacPermission[]): string {
  const ordered = macPermissions.filter(permission => permissions.includes(permission))
  if (ordered.length <= 2) return ordered.join(' and ')
  return `${ordered.slice(0, -1).join(', ')}, and ${ordered[ordered.length - 1]}`
}
