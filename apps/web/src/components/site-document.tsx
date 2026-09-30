import { Geist, Geist_Mono } from 'next/font/google'
import type { ReactNode } from 'react'
import { SiteFooter } from '@/components/site-footer'
import { SiteHeader } from '@/components/site-header'
import '@/app/globals.css'

const geist = Geist({ subsets: ['latin'], variable: '--font-geist' })
const geistMono = Geist_Mono({ subsets: ['latin'], variable: '--font-geist-mono' })

/**
 * The document and site chrome shared by both root layouts and the global 404. The site has two
 * root layouts, src/app/(analytics)/layout.tsx and src/app/(sensitive-url)/layout.tsx, so that
 * every navigation between them is a full page load: a page whose URL can carry checkout or
 * session data always starts a new document, which strips the query (`head`) before GTM loads.
 * Never render analytics from here: the 404 uses it too.
 *
 * `head` renders first in `<head>`, before anything in `<body>`; the (sensitive-url) layout and the
 * 404 pass `<StripQuery />`.
 */
export function SiteDocument({ children, head }: { children: ReactNode; head?: ReactNode }) {
  return (
    // The site has one dark theme; `dark` turns on the dark variants of shadcn components.
    <html lang="en" className={`dark ${geist.variable} ${geistMono.variable}`}>
      {/* biome-ignore lint/style/noHeadElement: an App Router root layout may render <head>; the rule is for next/head. Titles and meta still come from the Metadata API. */}
      <head>{head}</head>
      <body>
        <SiteHeader />
        {children}
        <SiteFooter />
      </body>
    </html>
  )
}
