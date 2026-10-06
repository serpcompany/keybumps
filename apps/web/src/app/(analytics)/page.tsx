import type { Metadata } from 'next'
import Image from 'next/image'
import Link from 'next/link'
import { PluginIcon } from '@/components/plugin-icon'
import { PricingCard } from '@/components/pricing-card'
import { getCurrentRelease } from '@/lib/latest-release'
import { linkPrefetch } from '@/lib/pages'
import { cardShortcut, pluginPath, plugins } from '@/lib/plugins'
import { pricing } from '@/lib/pricing'
import { PaletteDemo } from './palette-demo'

export const metadata: Metadata = {
  alternates: { canonical: '/' }
}

// Re-read the release pointer at most every five minutes.
export const revalidate = 300

const FAQ = [
  {
    q: 'What do I need to run Keybumps?',
    a: 'An Apple Silicon Mac running macOS 14.2 or later. Translation of dictations needs macOS 15.'
  },
  {
    q: 'Can I turn off the parts I don’t use?',
    a: 'Yes. Turn each plugin on or off in Settings › Plugins. Turning one off stops its shortcuts and background work.'
  },
  {
    q: 'Is it signed?',
    a: 'Yes. Every release is signed with Developer ID and delivered through signed in-app updates.'
  }
]

export default async function Home() {
  const release = await getCurrentRelease()

  return (
    <main>
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
            Keybumps puts search, clipboard history, screenshots, dictation, and the rest of the
            utilities you’d install one by one into a single native macOS app. It’s fast and
            private, and what you copy, capture, and dictate stays on your Mac.
          </p>
          <div className="cta-row">
            <a href={release.dmgURL} className="btn btn-lg">
              Download for macOS
            </a>
            <a href="#features" className="btn btn-lg btn-ghost">
              See what it does
            </a>
          </div>
          <p className="fine">Apple Silicon · macOS 14.2+ · Signed with Developer ID</p>
          <div className="demo-wrap">
            <div className="glow" />
            <PaletteDemo />
          </div>
        </div>
      </section>

      <section id="features" className="section">
        <div className="container">
          <h2>Replace a menu bar full of apps</h2>
          <p className="section-lede">
            Every plugin shares one Command Palette and one set of settings. Turn on only what you
            need.
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

      <section id="privacy" className="section">
        <div className="container split">
          <div>
            <h2>Private by design</h2>
            <p className="section-lede left">
              Keybumps is a native Swift app, not a web view. Your clipboard, screenshots, and voice
              recordings live in folders on your Mac that you can open, back up, or delete at any
              time.
            </p>
            <ul className="checks">
              <li>Speech-to-text runs on your Mac</li>
              <li>No cloud sync — nothing to breach</li>
              <li>Redact and blur screenshots before you share</li>
              <li>Developer ID–signed, auto-updating releases</li>
            </ul>
          </div>
          <div className="mascot-card">
            <Image
              src="/brand/mascot.png"
              alt="The Keybumps mascot"
              width={200}
              height={200}
              className="float"
            />
            <p>Copied to Clipboard</p>
          </div>
        </div>
      </section>

      <section id="pricing" className="section">
        <div className="container">
          <h2>{pricing.model.headline}</h2>
          <p className="section-lede">
            {pricing.model.summary} Try it risk-free for {pricing.refundDays} days.
          </p>
          <PricingCard />
        </div>
      </section>

      <section id="faq" className="section">
        <div className="container narrow">
          <h2>Questions</h2>
          <div className="faq">
            {FAQ.map(item => (
              <details key={item.q}>
                <summary>{item.q}</summary>
                <p>{item.a}</p>
              </details>
            ))}
          </div>
        </div>
      </section>

      <section className="section">
        <div className="container">
          <div className="final-cta">
            <Image src="/brand/app-icon.png" alt="" width={88} height={88} />
            <h2>Give your keys a bump.</h2>
            <p className="section-lede">Download the Keybumps beta and try every plugin today.</p>
            <a href={release.dmgURL} className="btn btn-lg">
              Download Keybumps {release.version}
            </a>
          </div>
        </div>
      </section>
    </main>
  )
}
