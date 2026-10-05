import Link from 'next/link'
import { PageShell } from '@/components/page-shell'
import { pageMetadata } from '@/lib/metadata'
import { linkPrefetch, pluginPages, sitePages } from '@/lib/pages'

export const metadata = pageMetadata('/sitemap/')

export default function HtmlSitemapPage() {
  return (
    <PageShell title="Sitemap">
      <ul>
        {sitePages.map(page => (
          <li key={page.path}>
            <Link
              href={page.path}
              prefetch={linkPrefetch(page.path)}
              className="underline underline-offset-4"
            >
              {page.title}
            </Link>
            {page.path === '/plugins/' && (
              <ul>
                {pluginPages.map(plugin => (
                  <li key={plugin.path}>
                    <Link
                      href={plugin.path}
                      prefetch={linkPrefetch(plugin.path)}
                      className="underline underline-offset-4"
                    >
                      {plugin.title}
                    </Link>
                  </li>
                ))}
              </ul>
            )}
          </li>
        ))}
      </ul>
    </PageShell>
  )
}
