import type { Metadata } from 'next'
import Image from 'next/image'
import Link from 'next/link'
import type { CSSProperties, ReactNode } from 'react'
import { DownloadLink } from '@/components/download-link'
import { Faq } from '@/components/faq'
import { JsonLd } from '@/components/json-ld'
import { PluginIcon } from '@/components/plugin-icon'
import { getCurrentRelease } from '@/lib/latest-release'
import { defaultOpenGraph } from '@/lib/metadata'
import { linkPrefetch } from '@/lib/pages'
import { cardShortcut, iconTints, pluginFor, pluginPath, plugins } from '@/lib/plugins'
import { site } from '@/lib/site'
import {
  ClipboardVisual,
  DictationVisual,
  ScreenshotVisual,
  SnippetsVisual,
  WindowsVisual
} from './home-visuals'
import { PaletteDemo } from './palette-demo'

/** The search-friendly title: what Keybumps does first, the name last (#298). */
const title = 'Clipboard History, Snippets & Dictation for Mac — Keybumps'

export const metadata: Metadata = {
  title: { absolute: title },
  alternates: { canonical: '/' },
  openGraph: { ...defaultOpenGraph, url: '/', title }
}

// Re-read the release pointer at most every five minutes.
export const revalidate = 300

/**
 * The plugins the home page shows in depth, in this order. Each one's features and options are
 * written from its entry in src/lib/plugins.ts, in plain words.
 */
const featured: readonly {
  slug: string
  headline: string
  lede: string
  features: readonly string[]
  options: { label: string; values: readonly string[] }
  visual: ReactNode
}[] = [
  {
    slug: 'clipboard-history',
    headline: 'Copy it once. Find it later.',
    lede: 'Everything you copy, text and images, searchable from one shortcut.',
    features: [
      'Your 50 most recent copies, text and images',
      'Shows the app each one came from, and the website’s domain when the browser says',
      'Copy an image file in Finder and get the image, not its icon',
      'Screenshots you take land here, ready to paste'
    ],
    options: { label: 'Opens with', values: ['⇧⌘ Space', '⌘2 in the palette'] },
    visual: <ClipboardVisual />
  },
  {
    slug: 'dictation',
    headline: 'Talk instead of type.',
    lede: 'Press ⌥ Space, say what you want to write, and press it again. Your words appear where your cursor was, in any app.',
    features: [
      'A timer and live sound bars at the notch while you speak',
      'Pause to think: it writes everything down after you stop',
      'Every recording kept in Dictation History to search, replay, and copy',
      'Translate what you said and hear it read aloud (macOS 15 or later)'
    ],
    options: { label: 'Recording limit', values: ['5 min', '10', '15', '30', '60', 'No limit'] },
    visual: <DictationVisual />
  },
  {
    slug: 'window-manager',
    headline: 'Every window where you want it, in one keystroke.',
    lede: 'Send a window to a half, a third, a corner, or your other display without reaching for the mouse.',
    features: [
      'Halves, corners, thirds, sixths, and fourths',
      'Maximize, center, make smaller or larger, restore',
      'Move a window to the next or previous display',
      'Drag a window to the top, a side, or a corner to snap it'
    ],
    options: { label: 'Your choice', values: ['30 window commands', 'Change any shortcut'] },
    visual: <WindowsVisual />
  },
  {
    slug: 'screenshot-tools',
    headline: 'Capture, mark up, and paste in seconds.',
    lede: 'Take a screenshot, cover what shouldn’t be seen, and paste it anywhere.',
    features: [
      'Blur, redact, arrows, drawing, and text',
      'Every screen, then edit (⇧⌘3) copies only when you save, so nothing unredacted reaches the clipboard',
      'Your screenshots in a grid of large thumbnails in their own tab'
    ],
    options: {
      label: 'Capture',
      values: ['Area ⇧⌘4', 'Every screen ⇧⌘2', 'Every screen, then edit ⇧⌘3']
    },
    visual: <ScreenshotVisual />
  },
  {
    slug: 'snippets',
    headline: 'Type it once. Never again.',
    lede: 'Save the text you reuse and paste it from the Command Palette, or turn on keyword expansion and type a short keyword in any app.',
    features: [
      'With keyword expansion on, keywords like ;ship expand as you type',
      'Sensitive snippets stay hidden and out of search',
      'Bring your snippets over from Alfred'
    ],
    options: { label: 'Use them', values: ['⌘5 in the palette', 'Quick Search', 'Type a keyword'] },
    visual: <SnippetsVisual />
  }
]

const useCases: readonly { title: string; text: string; plugins: readonly string[] }[] = [
  {
    title: 'Writing and editing',
    text: 'Keep the quotes and links you collect in Clipboard History, save sign-offs as snippets, and dictate a first draft when typing feels slow.',
    plugins: ['clipboard-history', 'snippets', 'dictation']
  },
  {
    title: 'Software development',
    text: 'Paste the command you copied an hour ago, put the editor and browser side by side, and grab a screenshot of the bug with the secrets blurred.',
    plugins: ['clipboard-history', 'window-manager', 'screenshot-tools']
  },
  {
    title: 'Customer support',
    text: 'Answer common questions with saved snippets, and send marked-up screenshots that show exactly where to click.',
    plugins: ['snippets', 'screenshot-tools', 'emoji-picker']
  },
  {
    title: 'Studying and research',
    text: 'Dictate notes, keep everything you copied from your sources searchable, and time focused sessions with a countdown in the menu bar.',
    plugins: ['dictation', 'clipboard-history', 'timer']
  },
  {
    title: 'Getting faster on a Mac',
    text: 'Shortcut Coach shows the shortcut when you do something by hand, and Quick Search opens any app or file from the keyboard.',
    plugins: ['shortcut-coach', 'quick-search']
  }
]

/** Real settings, drawn as the controls you'd find in Keybumps Settings. */
const settings: readonly { title: string; text: string; control: ReactNode }[] = [
  {
    title: 'Only the plugins you want',
    text: 'Turn a plugin off and its shortcuts and background work stop.',
    control: <Toggle on label="Clipboard History" />
  },
  {
    title: 'Your shortcuts',
    text: 'Change any shortcut. Some start unassigned until you pick one.',
    control: (
      <span className="keycaps">
        <kbd>⌥</kbd>
        <kbd>Space</kbd>
      </span>
    )
  },
  {
    title: 'Maximum recording length',
    text: 'Stop recording after 5 minutes, or give yourself longer.',
    control: <Dropdown value="5 minutes" />
  },
  {
    title: 'Quiet timers',
    text: 'Turn off the ringing, the menu bar countdown, or the menu list.',
    control: <Toggle on={false} label="Ring until you stop it" />
  },
  {
    title: 'Emoji skin tone',
    text: 'Set it once and it applies to every emoji that has one.',
    control: <Segments values={['✋', '✋🏻', '✋🏼', '✋🏽', '✋🏾', '✋🏿']} on="✋🏽" />
  },
  {
    title: 'Copy new screenshots to the clipboard',
    text: 'New screenshots can go straight to the clipboard, or not.',
    control: <Toggle on label="Copy new screenshots to the clipboard" />
  }
]

const questions = [
  {
    q: 'What can Keybumps replace?',
    a: 'A launcher, a clipboard manager, a text expander, a dictation app, a window manager, a screenshot editor, a menu bar timer, and an emoji picker. Turn on the ones you want.'
  },
  {
    q: 'Can I change the shortcuts?',
    a: 'Yes. Change any shortcut in Settings. Some start unassigned until you pick one.'
  },
  {
    q: 'Does Dictation work in any app?',
    a: 'Yes. Your words go where your cursor was when you started.'
  },
  {
    q: 'Can I bring my snippets from Alfred?',
    a: 'Yes. Keybumps imports an Alfred snippets export.'
  },
  {
    q: 'What do I need to run Keybumps?',
    a: 'An Apple silicon Mac running macOS 14.2 or later. Translating dictations needs macOS 15.'
  },
  {
    q: 'Can I move it to a new Mac?',
    a: 'Yes. Deactivate it in Settings on the old Mac, then activate it on the new one.'
  }
]

export default async function Home() {
  const release = await getCurrentRelease()

  return (
    <main>
      <JsonLd
        data={{
          '@type': 'SoftwareApplication',
          name: site.name,
          description: site.description,
          url: site.url,
          applicationCategory: 'UtilitiesApplication',
          operatingSystem: 'macOS 14.2 or later',
          softwareVersion: release.version,
          downloadUrl: release.dmgURL
        }}
      />

      <section className="hero">
        <div className="container hero-inner">
          <span className="pill">
            <span className="dot" /> Public beta · v{release.version}
          </span>
          <h1>
            Everything you reach for.
            <br />
            <span className="accent">One keyboard shortcut away.</span>
          </h1>
          <p className="lede">
            Search, clipboard history, screenshots, dictation, window snapping, and the rest of the
            utilities you’d install one by one, in a single native macOS app.
          </p>
          <div className="cta-row">
            <a href={release.dmgURL} className="btn btn-lg">
              Download for macOS
            </a>
            <a href="#features" className="btn btn-lg btn-ghost">
              See what it does
            </a>
          </div>
          <p className="fine">Apple silicon · macOS 14.2 or later</p>
          <div className="demo-wrap">
            <div className="glow" />
            <PaletteDemo />
            <p className="demo-hint">Click a tab to see what it holds.</p>
          </div>
        </div>
      </section>

      <section className="section">
        <div className="container">
          <h2>Three keys from anything</h2>
          <ol className="home-steps">
            <li>
              <h3>Open the Command Palette</h3>
              <p>From any app. Quick Search is the first tab.</p>
              <span className="keycaps">
                <kbd>⌘</kbd>
                <kbd>Space</kbd>
              </span>
            </li>
            <li>
              <h3>Jump to a tab</h3>
              <p>
                Clipboard, Screenshots, Dictation, Snippets, Timers, and Emoji, once you turn it on.
              </p>
              <span className="keycaps">
                <kbd>⌘</kbd>
                <kbd>1</kbd>
                <span className="keycaps-to">to</span>
                <kbd>⌘</kbd>
                <kbd>7</kbd>
              </span>
            </li>
            <li>
              <h3>Type, then press Return</h3>
              <p>Open the app or file, or copy the item you found.</p>
              <span className="keycaps">
                <kbd>↩</kbd>
              </span>
            </li>
          </ol>
        </div>
      </section>

      <section id="features" className="section">
        <div className="container">
          <h2>What’s inside</h2>
          <p className="section-lede">
            Each plugin does one job well. Here’s what five of them can do.
          </p>
          <div className="bands">
            {featured.map((item, index) => {
              const plugin = pluginFor(item.slug)
              const path = pluginPath(plugin.slug)
              return (
                <div
                  key={item.slug}
                  className={index % 2 ? 'band band-flip' : 'band'}
                  style={{ '--tint': iconTints[plugin.tint] } as CSSProperties}
                >
                  <div className="band-text">
                    <span className="band-eyebrow">
                      <PluginIcon systemImage={plugin.systemImage} tint={plugin.tint} size={24} />
                      {plugin.name}
                    </span>
                    <h3>{item.headline}</h3>
                    <p className="band-lede">{item.lede}</p>
                    <ul className="band-features">
                      {item.features.map(feature => (
                        <li key={feature}>{feature}</li>
                      ))}
                    </ul>
                    <p className="band-options">
                      <span>{item.options.label}</span>
                      {item.options.values.map(value => (
                        <span key={value} className="chip">
                          {value}
                        </span>
                      ))}
                    </p>
                    <Link href={path} prefetch={linkPrefetch(path)} className="band-more">
                      More about {plugin.name} →
                    </Link>
                  </div>
                  <div className="band-visual" aria-hidden="true">
                    {item.visual}
                  </div>
                </div>
              )
            })}
          </div>
        </div>
      </section>

      <section className="section">
        <div className="container">
          <h2>How people use it</h2>
          <p className="section-lede">Same app, different days. Turn on what your work needs.</p>
          <div className="use-cases">
            {useCases.map(useCase => (
              <div key={useCase.title} className="use-case">
                <h3>{useCase.title}</h3>
                <p>{useCase.text}</p>
                <ul className="use-case-plugins">
                  {useCase.plugins.map(pluginFor).map(plugin => {
                    const path = pluginPath(plugin.slug)
                    return (
                      <li key={plugin.slug}>
                        <Link href={path} prefetch={linkPrefetch(path)}>
                          <PluginIcon
                            systemImage={plugin.systemImage}
                            tint={plugin.tint}
                            size={18}
                          />
                          {plugin.name}
                        </Link>
                      </li>
                    )
                  })}
                </ul>
              </div>
            ))}
          </div>
        </div>
      </section>

      <section className="section">
        <div className="container">
          <h2>Set it up your way</h2>
          <p className="section-lede">
            Turn on what you use, change any shortcut, and tune each plugin in Settings.
          </p>
          <div className="settings-grid">
            {settings.map(setting => (
              <div key={setting.title} className="setting">
                <h3>{setting.title}</h3>
                <p>{setting.text}</p>
                <div aria-hidden="true">{setting.control}</div>
              </div>
            ))}
          </div>
        </div>
      </section>

      <section className="section">
        <div className="container">
          <h2>All plugins</h2>
          <p className="section-lede">
            Every plugin shares one Command Palette and one set of settings.
          </p>
          <div className="grid">
            {plugins.map(plugin => {
              const path = pluginPath(plugin.slug)
              const shortcut = cardShortcut(plugin)
              return (
                <Link key={plugin.slug} href={path} prefetch={linkPrefetch(path)} className="card">
                  <div className="card-head">
                    <div className="card-title">
                      <PluginIcon systemImage={plugin.systemImage} tint={plugin.tint} size={22} />
                      <h3>{plugin.name}</h3>
                    </div>
                    {shortcut && (
                      <kbd title={shortcut.label}>
                        {shortcut.keys}
                        <span className="sr-only">, {shortcut.label}</span>
                      </kbd>
                    )}
                  </div>
                  <p>{plugin.summary}</p>
                </Link>
              )
            })}
          </div>
        </div>
      </section>

      <section id="faq" className="section">
        <div className="container narrow">
          <h2>Questions</h2>
          <Faq questions={questions} />
        </div>
      </section>

      <section className="section">
        <div className="container">
          <div className="final-cta">
            <Image src="/brand/app-icon.png" alt="" width={88} height={88} />
            <h2>Give your keys a bump.</h2>
            <DownloadLink className="btn btn-lg">Download Keybumps {release.version}</DownloadLink>
          </div>
        </div>
      </section>
    </main>
  )
}

function Toggle({ on, label }: { on: boolean; label: string }) {
  return (
    <span className="toggle-mock">
      <i className={on ? 'toggle-knob on' : 'toggle-knob'} />
      {label}
    </span>
  )
}

function Dropdown({ value }: { value: string }) {
  return <span className="dropdown-mock">{value}</span>
}

function Segments({ values, on }: { values: readonly string[]; on: string }) {
  return (
    <span className="segments-mock">
      {values.map(value => (
        <span key={value} className={value === on ? 'on' : undefined}>
          {value}
        </span>
      ))}
    </span>
  )
}
