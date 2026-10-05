import Image from 'next/image'
import Link from 'next/link'
import { DownloadLink } from '@/components/download-link'

export function SiteHeader() {
  return (
    <header className="nav">
      <div className="container nav-inner">
        <Link href="/" className="brand">
          <Image src="/brand/app-icon.png" alt="" width={28} height={28} />
          Keybumps
        </Link>
        <nav className="nav-links">
          <Link href="/#features">Features</Link>
          <Link href="/plugins/">Plugins</Link>
          <Link href="/pricing/">Pricing</Link>
          <Link href="/#faq">FAQ</Link>
          <DownloadLink className="btn btn-sm">Download</DownloadLink>
        </nav>
      </div>
    </header>
  )
}
