import Link from 'next/link'
import { DownloadLink } from '@/components/download-link'

export function SiteFooter() {
  return (
    <footer className="footer">
      <div className="container footer-inner">
        <span>© {new Date().getFullYear()} SERP. Keybumps is a macOS app.</span>
        <nav>
          <Link href="/plugins/">Plugins</Link>
          <Link href="/pricing/">Pricing</Link>
          <DownloadLink>Download</DownloadLink>
          <Link href="/about/">About</Link>
          <Link href="/support/">Support</Link>
          <Link href="/contact/">Contact</Link>
          <Link href="/legal/terms/">Terms</Link>
          <Link href="/legal/privacy/">Privacy</Link>
          <Link href="/legal/refunds/">Refunds</Link>
          <Link href="/legal/">Legal</Link>
          <Link href="/license/" prefetch={false}>
            Lost your key?
          </Link>
          <Link href="/sitemap/">Sitemap</Link>
        </nav>
      </div>
    </footer>
  )
}
