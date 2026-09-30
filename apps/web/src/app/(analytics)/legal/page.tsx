import Link from 'next/link'
import { PageShell } from '@/components/page-shell'
import { pageMetadata } from '@/lib/metadata'
import { legalPages } from '@/lib/pages'

export const metadata = pageMetadata('/legal/')

export default function LegalIndexPage() {
  return (
    <PageShell title="Legal">
      <ul>
        {legalPages.map(page => (
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
