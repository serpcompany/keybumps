import Link from 'next/link'
import { PageShell } from '@/components/page-shell'
import { pageMetadata } from '@/lib/metadata'
import { sitePages } from '@/lib/pages'

export const metadata = pageMetadata('/sitemap/')

export default function HtmlSitemapPage() {
  return (
    <PageShell title="Sitemap">
      <ul>
        {sitePages.map(page => (
          <li key={page.path}>
            <Link href={page.path} className="underline underline-offset-4">
              {page.title}
            </Link>
          </li>
        ))}
      </ul>
    </PageShell>
  )
}
