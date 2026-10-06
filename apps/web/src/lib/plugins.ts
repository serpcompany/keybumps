/**
 * Every plugin in the Mac app, listed on /plugins/ and given its own page at /plugins/<slug>/.
 * The Swift on `main` is the source of truth: copy its wording, keep only what it confirms, and
 * update this when a plugin changes there (ADR 0006: a new plugin's PR or release also adds it to
 * the website).
 *
 * - `apps/macos/Keybumps/Capabilities/*Module.swift`: each `CapabilityDescriptor`'s title,
 *   Settings page summary, category, `systemImage`, `iconTint`, palette tab, required
 *   permissions, dependencies, and search keywords; Timer's preferences; Snippets' optional
 *   permissions.
 * - `apps/macos/Keybumps/Capabilities/PluginManifest.swift`: `PluginCategory`, and the publisher
 *   (every plugin is official, by Keybumps).
 * - `apps/macos/Keybumps/Infrastructure/GlobalShortcutCoordinator.swift`: the `CapabilityShortcut`
 *   titles and default bindings (`DefaultShortcut`), and Dictation's Escape.
 * - `apps/macos/Keybumps/Capabilities/CapabilityModule.swift`: `CapabilityCatalog.descriptors`
 *   (the order) and `CapabilityCatalog.defaultCapabilities`.
 * - `apps/macos/Keybumps/WindowManagement/WindowAction.swift`: Window Manager's 30 window
 *   commands, their titles and default shortcuts, in `WindowSettingsLayout` order.
 * - `apps/macos/Keybumps/Infrastructure/SystemServices.swift`: the `MacPermission` titles and
 *   explanations, which the permission reasons follow.
 * - Overviews, features, and what each keeps: the Settings pages (`Views/SettingsRootView.swift`,
 *   `Views/SnippetsSettingsView.swift`, the Timer preferences in `TimerModule.swift`), `README.md`,
 *   `CONTEXT.md`, and `docs/releases/*.md`.
 */

/** `PluginCategory`: the categories plugins are listed under. */
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

/** A macOS permission a plugin uses, and what for, as `MacPermission.explanation` puts it. */
export type PluginPermission = {
  permission: MacPermission
  reason: string
}

export type Plugin = {
  /** Its page, /plugins/<slug>/. */
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
  /** The descriptor's `searchKeywords`: other words the search on /plugins/ matches. */
  keywords: readonly string[]
  /** Its Command Palette tab and the Command-number that selects it, if it has one. */
  paletteTab: {
    name: string
    commandKey: number
    /** The tab is hidden until a setting on the plugin's page shows it. */
    hiddenUnless?: string
  } | null
  /** Its shortcuts, in the order its Settings page lists them. */
  shortcuts: readonly PluginShortcut[]
  /** macOS permissions it needs while it's on, with why. */
  permissions: readonly PluginPermission[]
  /** Permissions it can use without needing them, with why. */
  optionalPermissions?: readonly PluginPermission[]
  /** Slugs of the plugins it needs turned on. */
  requires: readonly string[]
  /** One of the default capabilities, the set Keybumps's features were locked at. */
  isDefault: boolean
  /** The newest added capability, marked New on /plugins/. */
  isNew?: boolean
  /** Its page's Overview: one or two paragraphs. */
  overview: readonly string[]
  /** Its page's Key features, one line each. */
  features: readonly string[]
  /** What it keeps, and where: all of it on this Mac. */
  keeps: readonly string[]
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
    keywords: [],
    paletteTab: { name: 'Search', commandKey: 1 },
    shortcuts: [{ title: 'Open Quick Search', keys: '⌘ Space' }],
    permissions: [],
    requires: [],
    isDefault: true,
    overview: [
      'Quick Search opens the apps, files, and folders on your Mac from the keyboard. Press ⌘ Space, type a few letters, and press Return to open the result.',
      'It is the first tab of the Command Palette. Besides apps, files, and folders, it finds your snippets by keyword or name, and typing a plugin’s name, such as “dictation” or “snippets”, takes you straight to it.'
    ],
    features: [
      'Open apps, files, and folders without leaving the keyboard',
      'Recent Items: what you last opened from Quick Search, listed while the search is empty',
      'Apps and commands you pick more often rank higher, weighed against how well they match',
      'Finds snippets by keyword and name; a keyword typed in full comes first',
      'Type a plugin’s name to go to it, or open Keybumps Settings',
      'If Spotlight uses ⌘ Space, Keybumps turns off only Spotlight’s shortcut; Spotlight search stays available'
    ],
    keeps: [
      'Recent Items, and how often you pick each app or command, stay on this Mac. That count only ranks results, and no search is kept.'
    ]
  },
  {
    slug: 'clipboard-history',
    capability: 'clipboardHistory',
    name: 'Clipboard History',
    summary: 'Search text and images you copied earlier and paste them again.',
    category: 'Productivity',
    systemImage: 'clipboard',
    tint: 'orange',
    keywords: ['copy', 'copied', 'paste'],
    paletteTab: { name: 'Clipboard', commandKey: 2 },
    shortcuts: [{ title: 'Open Clipboard History', keys: '⇧⌘ Space' }],
    permissions: [],
    requires: [],
    isDefault: true,
    overview: [
      'Clipboard History keeps the text and images you copy, so you can use them again. Press ⇧⌘ Space to open the Clipboard tab of the Command Palette, search for an item, and press Return to copy it.',
      'Each item shows the app it was copied from, and for a web page the site’s domain, whenever macOS can tell. Screenshots you take with Screenshot Tools land here too, ready to paste.'
    ],
    features: [
      'Keeps your 50 most recent copied text and image items',
      'Search everything you copied, then press Return to copy it again',
      'Shows the app each item came from, and the website’s domain when a browser says which page it was',
      'Copying an image file in Finder keeps the image, not its icon',
      'Delete removes the highlighted item, and each copy confirms with a notice at the notch',
      'Text that Dictation inserts stays out, so the history holds only what you copied'
    ],
    keeps: [
      'Your history stays on this Mac. Images up to 50 MB each are stored separately, so a full history can use several gigabytes.',
      'Copied secrets remain until you delete them or newer copies replace them. For a website, only its domain is kept, never the full address.'
    ]
  },
  {
    slug: 'screenshot-tools',
    capability: 'screenshotTools',
    name: 'Screenshot Tools',
    summary: 'Take screenshots, keep them in Clipboard History, and mark them up.',
    category: 'Media',
    systemImage: 'camera.viewfinder',
    tint: 'purple',
    keywords: ['screenshots', 'screenshot', 'screen', 'capture', 'annotate'],
    paletteTab: { name: 'Screenshots', commandKey: 3 },
    shortcuts: [
      { title: 'Screenshot Screen', keys: '⇧⌘2' },
      { title: 'Screenshot Screen and Edit', keys: '⇧⌘3' },
      { title: 'Screenshot Area', keys: '⇧⌘4' }
    ],
    permissions: [
      {
        permission: 'Screen Recording',
        reason: 'Lets Screenshot Tools take screenshots with its hotkeys.'
      }
    ],
    requires: ['clipboard-history'],
    isDefault: true,
    overview: [
      'Screenshot Tools takes screenshots with its own hotkeys and puts them in Clipboard History, ready to paste. ⇧⌘2 captures every screen, ⇧⌘3 captures every screen and opens the editor, and ⇧⌘4 captures an area you select.',
      'Mark up a screenshot, or any image you copied, with blur, redact, arrow, draw, and text. Save copies the result and keeps an edited copy beside the original.'
    ],
    features: [
      'Hotkeys for every screen, every screen then edit, and a selected area; each can be changed',
      'Screenshots from these hotkeys and from macOS’s own ⇧⌘5 appear in Clipboard History and the Screenshots tab, a grid of large thumbnails',
      'New screenshots also go on the clipboard, unless you turn that off or copied something since',
      'An editor with blur, redact, arrow, draw, and text; Save (Return) copies the result and saves “<name> (edited).png” beside the original',
      'Screenshot Screen and Edit copies only when you Save, so an unredacted shot never lands on the clipboard',
      'In the Screenshots tab, Return copies a screenshot and ⌘Return opens it in the editor; ⌘E edits any image in Clipboard History',
      'While it’s on, Keybumps uses ⇧⌘3 and ⇧⌘4 in place of macOS’s own, and gives them back when you turn it off'
    ],
    keeps: [
      'Screenshots are saved where macOS saves screenshots, and edited copies beside the original. Clipboard History keeps them on this Mac.'
    ]
  },
  {
    slug: 'dictation',
    capability: 'dictation',
    name: 'Dictation',
    summary: 'Speech to text anywhere, transcribed on this Mac.',
    category: 'Writing',
    systemImage: 'waveform',
    tint: 'blue',
    keywords: [
      'dictate',
      'voice',
      'speech',
      'transcribe',
      'transcription',
      'transcript',
      'recording',
      'recordings',
      'history'
    ],
    paletteTab: { name: 'Dictation', commandKey: 4 },
    shortcuts: [{ title: 'Start or stop Dictation', keys: '⌥ Space' }],
    permissions: [
      {
        permission: 'Accessibility',
        reason: 'Lets Dictation return text to the original cursor.'
      },
      {
        permission: 'Microphone',
        reason: 'Lets Dictation record only while its recording indicator is visible.'
      },
      {
        permission: 'Speech Recognition',
        reason: 'Lets Apple transcribe Dictation locally on this Mac.'
      }
    ],
    requires: [],
    isDefault: true,
    overview: [
      'Dictation turns speech into text in any app. Press ⌥ Space to start recording and press it again to stop: Keybumps transcribes the recording on this Mac and inserts the text where your cursor was.',
      'Transcribe with Apple Speech, built into macOS, or with a Whisper model you download. Every recording and its transcript stays in Dictation History, the Command Palette’s Dictation tab, where you can search, play, and copy them.'
    ],
    features: [
      'Start and stop with ⌥ Space; Escape cancels while it records or transcribes',
      'Inserts the transcript at the cursor where you started',
      'Apple Speech, built in, or a downloadable Whisper model: Medium English, or Medium Multilingual and Large v3 Turbo for English and Japanese',
      'The notch shows a recording timer and live microphone bars while you speak',
      'Records up to five minutes by default; choose 10, 15, 30, or 60 minutes, or no limit',
      'Transcribes the whole recording after you stop, so a pause never cuts it short',
      'Dictation History: search, play back, copy, reveal in Finder, and delete recordings',
      'On macOS 15 or later, translate a transcript on this Mac and hear it in an installed macOS voice'
    ],
    keeps: [
      'Recordings and transcripts are kept in ~/Documents/Keybumps/recordings on this Mac, where you can open or delete them.',
      'Downloaded models stay on this Mac, and audio is transcribed locally with the model you choose.'
    ]
  },
  {
    slug: 'window-manager',
    capability: 'windowManagement',
    name: 'Window Manager',
    summary: 'Move and resize your application windows.',
    category: 'Productivity',
    systemImage: 'rectangle.split.2x1',
    tint: 'teal',
    keywords: ['windows', 'snap', 'resize', 'tile', 'tiling'],
    paletteTab: null,
    shortcuts: [
      { title: 'Left', keys: '⌃⌥⌘←' },
      { title: 'Right', keys: '⌃⌥⌘→' },
      { title: 'Center', keys: '⌃⌥⌘5' },
      { title: 'Top', keys: '⌃⌥⇧⌘↑' },
      { title: 'Bottom', keys: '⌃⌥⇧⌘↓' },
      { title: 'Top Left', keys: '⌃⌥U' },
      { title: 'Top Right', keys: null },
      { title: 'Bottom Left', keys: '⌃⌥J' },
      { title: 'Bottom Right', keys: '⌃⌥K' },
      { title: 'Maximize', keys: '⌃⌥⌘↑' },
      { title: 'Make Smaller', keys: '⌃⌥-' },
      { title: 'Make Larger', keys: '⌃⌥=' },
      { title: 'Move to Center', keys: '⌃⌥⌘M' },
      { title: 'Restore', keys: '⌃⌥⌫' },
      { title: 'Next Display', keys: '⌃⌥→' },
      { title: 'Previous Display', keys: '⌃⌥←' },
      { title: 'First Third', keys: '⌃⌥⌘1' },
      { title: 'Center Third', keys: '⌃⌥⌘2' },
      { title: 'Last Third', keys: '⌃⌥⌘3' },
      { title: 'First Two Thirds', keys: '⌃⌥⌘4' },
      { title: 'Last Two Thirds', keys: '⌃⌥⌘6' },
      { title: 'Top Left Sixth', keys: '⌃⌥⇧⌘4' },
      { title: 'Top Center Sixth', keys: '⌃⌥⇧⌘5' },
      { title: 'Top Right Sixth', keys: '⌃⌥⇧⌘6' },
      { title: 'Bottom Left Sixth', keys: '⌃⌥⇧⌘7' },
      { title: 'Bottom Center Sixth', keys: '⌃⌥⇧⌘8' },
      { title: 'Bottom Right Sixth', keys: '⌃⌥⇧⌘9' },
      { title: 'Last Fourth', keys: '⌃⌥⌘↘' },
      { title: 'First Three Fourths', keys: '⌃⌥⌘7' },
      { title: 'Last Three Fourths', keys: '⌃⌥⌘9' }
    ],
    permissions: [
      {
        permission: 'Accessibility',
        reason: 'Lets Window Manager move and resize other apps’ windows.'
      }
    ],
    requires: [],
    isDefault: true,
    overview: [
      'Window Manager moves and resizes the window you’re using with a shortcut: halves, corners, thirds, sixths, and fourths of the screen, maximize, center, and the next or previous display.',
      'All but one of its 30 window commands start with a shortcut, and you can change any of them in Settings. Drag a window to the top, a side, or a corner of the screen to snap it. Its behavior is derived from Rectangle, the open-source window manager.'
    ],
    features: [
      '30 window commands: halves, corners, thirds, two-thirds, sixths, and fourths of the screen',
      'Maximize, Make Smaller, Make Larger, Move to Center, and Restore',
      'Move a window to the next or previous display',
      'Drag a window to the top edge to maximize it, a side to fill that half, or a corner to fill that quarter',
      'Change any shortcut in Settings, or Restore Defaults'
    ],
    keeps: [
      'Window Manager works with the windows already on your screen and keeps only its shortcuts, in Keybumps’s settings on this Mac.'
    ]
  },
  {
    slug: 'shortcut-coach',
    capability: 'keyboardShortcutter',
    name: 'Shortcut Coach',
    summary: 'Learn the shortcuts for actions you do by hand.',
    category: 'Productivity',
    systemImage: 'keyboard',
    tint: 'gray',
    keywords: ['hotkeys', 'hotkey', 'shortcuts', 'keyboard', 'history'],
    paletteTab: {
      name: 'Hotkeys',
      commandKey: 7,
      hiddenUnless: 'Show Hotkeys tab in the Command Palette'
    },
    shortcuts: [],
    permissions: [
      {
        permission: 'Accessibility',
        reason:
          'With Input Monitoring, lets Shortcut Coach recognize supported actions outside Keybumps.'
      },
      {
        permission: 'Input Monitoring',
        reason:
          'Lets Shortcut Coach recognize supported mouse and keyboard actions outside Keybumps.'
      }
    ],
    requires: [],
    isDefault: true,
    overview: [
      'Shortcut Coach notices when you do something by hand that has a keyboard shortcut, such as choosing a menu command with the mouse, and shows you the shortcut. The tip drops down from the notch with the app’s icon, the action, and its keys.',
      'Each action it notices goes into its history, which you can view, filter, and clear in the Command Palette’s Hotkeys tab once you turn the tab on.'
    ],
    features: [
      'Recognizes supported actions you do by hand that have a shortcut',
      'Shows the shortcut at the notch: the app’s icon, the action and app, and the keys',
      'A history of detected actions in the Hotkeys tab, to view, filter, and clear',
      'Send Test Suggestion in Settings shows what a tip looks like',
      'A legend of the keyboard symbols in Settings'
    ],
    keeps: ['Its history of detected actions stays on this Mac until you clear it.']
  },
  {
    slug: 'snippets',
    capability: 'snippets',
    name: 'Snippets',
    summary: 'Save text you reuse, then copy or paste it from the Command Palette.',
    category: 'Writing',
    systemImage: 'text.quote',
    tint: 'green',
    keywords: ['snippet', 'snip'],
    paletteTab: { name: 'Snippets', commandKey: 5 },
    shortcuts: [{ title: 'Open Snippets', keys: null }],
    permissions: [],
    optionalPermissions: [
      {
        permission: 'Accessibility',
        reason:
          'Lets ⌘Return paste a snippet into the app you’re using; without it, ⌘Return copies. Expanding keywords needs it too.'
      },
      {
        permission: 'Input Monitoring',
        reason:
          'Lets Snippets notice when you type a keyword, for keyword expansion, which is off until you turn it on.'
      }
    ],
    requires: [],
    isDefault: true,
    overview: [
      'Snippets keeps text you reuse, each with a name and an optional keyword such as ;ship. Open the Snippets tab of the Command Palette, then press Return to copy a snippet or ⌘Return to paste it into the app you’re using.',
      'Turn on keyword expansion, and typing a keyword in any app replaces it with its snippet. Mark a snippet sensitive to keep its text in your Mac’s Keychain and out of sight.'
    ],
    features: [
      'Save text with a name and an optional keyword, such as ;ship',
      'Return copies a snippet, and ⌘Return pastes it into the app you’re using',
      'Expand keywords as you type in any app, then get your clipboard back; never in password fields or in Keybumps itself',
      'Sensitive snippets hide their text in the Command Palette and Settings, stay out of search, and are kept in the Keychain',
      'Quick Search finds snippets by keyword and name',
      'Import an Alfred snippets export',
      'Sort snippets by column, and select several to delete them or mark them sensitive together'
    ],
    keeps: [
      'Snippets are kept on this Mac only. A sensitive snippet’s text is kept in your Mac’s Keychain instead of the snippets file.'
    ]
  },
  {
    slug: 'timer',
    capability: 'timer',
    name: 'Timer',
    summary: 'Count down from a duration and get told when it ends.',
    category: 'Productivity',
    systemImage: 'timer',
    tint: 'orange',
    keywords: ['timers', 'countdown'],
    paletteTab: { name: 'Timers', commandKey: 6 },
    shortcuts: [{ title: 'Open Timers', keys: null }],
    permissions: [],
    requires: [],
    isDefault: false,
    isNew: true,
    overview: [
      'Timer counts down from a duration you type. Open the Timers tab of the Command Palette, type 5m, 1h30m, or tea 25, and press Return.',
      'While a timer runs, the soonest one counts down beside the Keybumps icon in the menu bar. When it ends, an alarm stays on screen and rings until you click Stop or Repeat, or open the Timers tab. Timer is the first plugin added to Keybumps.'
    ],
    features: [
      'Start a timer by typing a duration, with an optional name: 5m, 1h30m, or tea 25',
      'Pause, restart, or delete timers in the Timers tab',
      'The soonest timer counts down in the menu bar, with a count of any others',
      'The Keybumps menu lists your timers; click one to pause or resume it',
      'An alarm that stays on screen until you click Stop or Repeat, or open the Timers tab; turn ringing off for a silent one',
      'Never rings while you’re dictating',
      'Timers keep counting through sleep and restarts',
      'Turn off the ringing, the menu bar countdown, or the menu list in Settings'
    ],
    keeps: ['Timers, with any names you give them, are kept on this Mac until you delete them.']
  }
]

export function pluginFor(slug: string): Plugin {
  const plugin = plugins.find(candidate => candidate.slug === slug)
  if (!plugin) throw new Error(`Unknown plugin: ${slug}`)
  return plugin
}

/** A plugin's page. */
export function pluginPath(slug: string): `/plugins/${string}/` {
  return `/plugins/${slug}/`
}

/** The plugins in a category. */
export function pluginsIn(category: PluginCategory): Plugin[] {
  return plugins.filter(plugin => plugin.category === category)
}

/**
 * The plugins a plugin's page suggests: the next ones in catalog order, wrapping around, so each
 * plugin is suggested from as many pages as any other, and never on its own.
 */
export function otherPlugins(slug: string, count = 3): Plugin[] {
  const index = plugins.indexOf(pluginFor(slug))
  return Array.from(
    { length: Math.min(count, plugins.length - 1) },
    (_, offset) => plugins[(index + offset + 1) % plugins.length]
  )
}

/** Its commands: its palette tab, if it has one, and its shortcuts. */
/**
 * The key a home page card shows, with a tooltip saying what kind it is: its first default hotkey,
 * which works from any app, or else the Command-number of its Command Palette tab. Null when it has
 * neither, or its tab is hidden until a setting shows it.
 */
export function cardShortcut(plugin: Plugin): { keys: string; label: string } | null {
  const hotkey = plugin.shortcuts.find(shortcut => shortcut.keys)
  if (hotkey?.keys) return { keys: hotkey.keys, label: `${hotkey.title}, from any app` }
  const tab = plugin.paletteTab
  if (!tab || tab.hiddenUnless) return null
  return { keys: `⌘${tab.commandKey}`, label: `Its Command Palette tab, ${tab.name}` }
}

export function commandCount(plugin: Plugin): number {
  return (plugin.paletteTab ? 1 : 0) + plugin.shortcuts.length
}

/** The words the search on /plugins/ matches, in lowercase. */
export function searchTerms(plugin: Plugin): string {
  return [plugin.name, plugin.summary, plugin.category, plugin.paletteTab?.name, ...plugin.keywords]
    .filter(Boolean)
    .join(' ')
    .toLowerCase()
}

const modifierKeys = new Set(['⌃', '⌥', '⇧', '⌘'])

/**
 * A shortcut as keycaps, one per key: "⇧⌘ Space" is ⇧, ⌘, Space, and "⌃⌥⌘←" is ⌃, ⌥, ⌘, ←.
 */
export function keycaps(keys: string): string[] {
  const caps: string[] = []
  let rest = keys.trim()
  while (rest && modifierKeys.has(rest[0])) {
    caps.push(rest[0])
    rest = rest.slice(1).trim()
  }
  if (rest) caps.push(rest)
  return caps
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
