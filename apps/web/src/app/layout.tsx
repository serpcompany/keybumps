import type { Metadata } from 'next'
import { Geist, Geist_Mono } from 'next/font/google'
import { Analytics } from '@/components/analytics'
import { SiteFooter } from '@/components/site-footer'
import { SiteHeader } from '@/components/site-header'
import { site } from '@/lib/site'
import './globals.css'

const geist = Geist({ subsets: ['latin'], variable: '--font-geist' })
const geistMono = Geist_Mono({ subsets: ['latin'], variable: '--font-geist-mono' })

export const metadata: Metadata = {
  metadataBase: new URL(site.url),
  title: {
    default: 'Keybumps — Six Mac utilities, one shortcut away',
    template: `%s — ${site.name}`
  },
  description: site.description,
  openGraph: { siteName: site.name, type: 'website', locale: 'en_US' }
}

export default function RootLayout({ children }: LayoutProps<'/'>) {
  return (
    // The site has one dark theme; `dark` turns on the dark variants of shadcn components.
    <html lang="en" className={`dark ${geist.variable} ${geistMono.variable}`}>
      <body>
        <SiteHeader />
        {children}
        <SiteFooter />
        <Analytics />
      </body>
    </html>
  )
}
