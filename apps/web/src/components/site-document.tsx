import type { Metadata } from 'next'
import { Geist, Geist_Mono } from 'next/font/google'
import type { ReactNode } from 'react'
import { SiteFooter } from '@/components/site-footer'
import { SiteHeader } from '@/components/site-header'
import { site } from '@/lib/site'
import '@/app/globals.css'

const geist = Geist({ subsets: ['latin'], variable: '--font-geist' })
const geistMono = Geist_Mono({ subsets: ['latin'], variable: '--font-geist-mono' })

/** Metadata shared by both root layouts and the global 404. */
export const siteMetadata: Metadata = {
  metadataBase: new URL(site.url),
  title: {
    default: 'Keybumps — Six Mac utilities, one shortcut away',
    template: `%s — ${site.name}`
  },
  description: site.description,
  openGraph: { siteName: site.name, type: 'website', locale: 'en_US' }
}

/**
 * Root layout metadata. src/app/opengraph-image.jpg sits above the route groups, and with no
 * shared root layout Next.js no longer attaches it to grouped pages, so the layouts name it
 * explicitly, with the same URL, cache key, type, and size Next.js generated for it before.
 * Update the query and size together if the image changes.
 */
export const rootLayoutMetadata: Metadata = {
  ...siteMetadata,
  openGraph: {
    ...siteMetadata.openGraph,
    images: [
      {
        url: '/opengraph-image.jpg?opengraph-image.0-pf82j9iav8s.jpg',
        type: 'image/jpeg',
        width: 1200,
        height: 630
      }
    ]
  }
}

/**
 * The document and site chrome shared by both root layouts. The site has two root layouts,
 * src/app/(analytics)/layout.tsx and src/app/(no-analytics)/layout.tsx, so that every navigation
 * between them is a full page load: a page without analytics never runs in a document where GTM
 * has loaded. Never render analytics from here.
 */
export function SiteDocument({ children }: { children: ReactNode }) {
  return (
    // The site has one dark theme; `dark` turns on the dark variants of shadcn components.
    <html lang="en" className={`dark ${geist.variable} ${geistMono.variable}`}>
      <body>
        <SiteHeader />
        {children}
        <SiteFooter />
      </body>
    </html>
  )
}
