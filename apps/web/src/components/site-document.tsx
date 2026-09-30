import { Geist, Geist_Mono } from 'next/font/google'
import type { ReactNode } from 'react'
import { SiteFooter } from '@/components/site-footer'
import { SiteHeader } from '@/components/site-header'
import '@/app/globals.css'

const geist = Geist({ subsets: ['latin'], variable: '--font-geist' })
const geistMono = Geist_Mono({ subsets: ['latin'], variable: '--font-geist-mono' })

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
