import Image from 'next/image';
import { PricingCard, SiteFooter, SiteHeader } from '../components/site-chrome';
import { getLatestRelease } from '../lib/latest-release';
import { PaletteDemo } from './palette-demo';

// Re-read the release pointer at most every five minutes.
export const revalidate = 300;

const FEATURES = [
  {
    title: 'Quick Search',
    keys: '⌘1',
    body: 'Find apps, files, and folders on your Mac from one keyboard-first palette.',
  },
  {
    title: 'Clipboard History',
    keys: '⌘2',
    body: 'Your last fifty copies — text and images, with previews. Delete what you don’t want kept.',
  },
  {
    title: 'Screenshot Tools',
    keys: '⇧⌘4',
    body: 'Capture an area or every screen, then pixelate, redact, draw, and annotate before you paste.',
  },
  {
    title: 'On-device Dictation',
    keys: '⌥Space',
    body: 'Talk and your words land at the cursor. Transcribed locally with Whisper — audio never leaves your Mac.',
  },
  {
    title: 'Window Manager',
    keys: '⌃⌥←',
    body: 'Snap windows to halves, thirds, and corners with shortcuts you choose.',
  },
  {
    title: 'Shortcut Coach',
    keys: '⌘5',
    body: 'Notices when you reach for the mouse and nudges you toward the shortcut that does it faster.',
  },
];

const FAQ = [
  {
    q: 'What do I need to run Keybumps?',
    a: 'An Apple Silicon Mac running macOS 14.2 or later. Translation of dictations needs macOS 15.',
  },
  {
    q: 'Does my data leave my Mac?',
    a: 'No. Search, clipboard history, screenshots, and dictation transcripts are stored and processed locally. Keybumps only contacts our servers to check for updates and validate your license.',
  },
  {
    q: 'Can I turn off the parts I don’t use?',
    a: 'Yes. Each capability is enabled independently, and turning one off stops its shortcuts and background work.',
  },
  {
    q: 'Is it signed and notarized?',
    a: 'Yes. Every release is Developer ID–signed, notarized by Apple, and delivered through signed in-app updates.',
  },
];

export default async function Home() {
  const release = await getLatestRelease();

  return (
    <>
      <SiteHeader downloadHref={release.dmgURL} />

      <main>
        <section className="hero">
          <div className="container hero-inner">
            <span className="pill">
              <span className="dot" /> Public beta · v{release.version}
            </span>
            <h1>
              Six Mac utilities.
              <br />
              <span className="accent">One keyboard shortcut away.</span>
            </h1>
            <p className="lede">
              Keybumps brings search, clipboard history, screenshots, dictation,
              window management, and shortcut coaching into a single native
              macOS app — fast, private, and entirely on-device.
            </p>
            <div className="cta-row">
              <a href={release.dmgURL} className="btn btn-lg">
                Download for macOS
              </a>
              <a href="#features" className="btn btn-lg btn-ghost">
                See what it does
              </a>
            </div>
            <p className="fine">
              Apple Silicon · macOS 14.2+ · Notarized by Apple
            </p>
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
              Every capability shares one Command Palette and one set of
              settings. Enable only what you need.
            </p>
            <div className="grid">
              {FEATURES.map((f) => (
                <article key={f.title} className="card">
                  <div className="card-head">
                    <h3>{f.title}</h3>
                    <kbd>{f.keys}</kbd>
                  </div>
                  <p>{f.body}</p>
                </article>
              ))}
            </div>
          </div>
        </section>

        <section id="privacy" className="section">
          <div className="container split">
            <div>
              <h2>Private by design</h2>
              <p className="section-lede left">
                Keybumps is a native Swift app, not a web view. Your clipboard,
                screenshots, and voice recordings live in folders on your Mac
                that you can open, back up, or delete at any time.
              </p>
              <ul className="checks">
                <li>Speech-to-text runs locally with Whisper</li>
                <li>No cloud sync — nothing to breach</li>
                <li>Redact and pixelate screenshots before you share</li>
                <li>Signed, notarized, auto-updating releases</li>
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
            <h2>One price. Yours to keep.</h2>
            <p className="section-lede">
              No subscription, no account. Try it risk-free for 30 days.
            </p>
            <PricingCard />
          </div>
        </section>

        <section id="faq" className="section">
          <div className="container narrow">
            <h2>Questions</h2>
            <div className="faq">
              {FAQ.map((item) => (
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
              <p className="section-lede">
                Download the Keybumps beta and try every capability today.
              </p>
              <a href={release.dmgURL} className="btn btn-lg">
                Download Keybumps {release.version}
              </a>
            </div>
          </div>
        </section>
      </main>

      <SiteFooter />
    </>
  );
}
