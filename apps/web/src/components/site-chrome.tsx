import Image from 'next/image';
import Link from 'next/link';
import type { ReactNode } from 'react';
import { CHECKOUT_URL, LEGAL_UPDATED, PRICE, SUPPORT_EMAIL } from '../lib/site';

export function SiteHeader({
  downloadHref = '/download',
}: {
  downloadHref?: string;
}) {
  return (
    <header className="nav">
      <div className="container nav-inner">
        <Link href="/" className="brand">
          <Image src="/brand/app-icon.png" alt="" width={28} height={28} />
          Keybumps
        </Link>
        <nav className="nav-links">
          <Link href="/#features">Features</Link>
          <Link href="/pricing">Pricing</Link>
          <Link href="/#faq">FAQ</Link>
          <a href={downloadHref} className="btn btn-sm">
            Download
          </a>
        </nav>
      </div>
    </header>
  );
}

export function SiteFooter() {
  return (
    <footer className="footer">
      <div className="container footer-inner">
        <span>© {new Date().getFullYear()} SERP. Keybumps is a macOS app.</span>
        <nav>
          <Link href="/pricing">Pricing</Link>
          <Link href="/download">Download</Link>
          <Link href="/terms">Terms</Link>
          <Link href="/privacy">Privacy</Link>
          <Link href="/refunds">Refunds</Link>
          <Link href="/license">Lost your key?</Link>
          <a href={`mailto:${SUPPORT_EMAIL}`}>Support</a>
        </nav>
      </div>
    </footer>
  );
}

const INCLUDED = [
  'All six capabilities: Search, Clipboard, Screenshots, Dictation, Windows, Shortcut Coach',
  'License for 1 Mac — move it to a new Mac any time',
  'All future updates included',
  'Everything runs on-device — no account needed',
  '30-day money-back guarantee',
];

export function PricingCard() {
  return (
    <div className="price-card">
      <div className="price-head">
        <h3>Keybumps</h3>
        <span className="pill">One-time purchase</span>
      </div>
      <p className="price">
        {PRICE}
        <span> USD · 1 Mac</span>
      </p>
      <ul className="checks">
        {INCLUDED.map((item) => (
          <li key={item}>{item}</li>
        ))}
      </ul>
      <a href={CHECKOUT_URL ?? '/download'} className="btn btn-lg price-cta">
        {CHECKOUT_URL ? `Buy Keybumps — ${PRICE}` : 'Download Keybumps'}
      </a>
      <p className="fine">
        Taxes calculated at checkout. Payments are processed by Polar, our
        merchant of record. See the <Link href="/refunds">refund policy</Link>.
      </p>
    </div>
  );
}

export function LegalPage({
  title,
  children,
  showUpdated = true,
}: {
  title: string;
  children: ReactNode;
  /** Legal documents show when they last changed; help pages don't. */
  showUpdated?: boolean;
}) {
  return (
    <>
      <SiteHeader />
      <main className="section legal">
        <div className="container narrow">
          <h1>{title}</h1>
          {showUpdated && <p className="fine">Last updated {LEGAL_UPDATED}</p>}
          {children}
        </div>
      </main>
      <SiteFooter />
    </>
  );
}
