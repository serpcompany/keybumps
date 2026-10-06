import Link from 'next/link'
import { JsonLd } from '@/components/json-ld'
import { linkPrefetch } from '@/lib/pages'
import { absoluteUrl } from '@/lib/site'

export type Crumb = { label: string; href: string }

/** Where a page sits, from Home down to the page itself, with its BreadcrumbList data. */
export function Breadcrumbs({ trail }: { trail: readonly Crumb[] }) {
  return (
    <>
      <nav aria-label="Breadcrumb">
        <ol className="crumbs">
          {trail.map((crumb, index) => (
            <li key={crumb.href}>
              {index === trail.length - 1 ? (
                <span aria-current="page">{crumb.label}</span>
              ) : (
                <Link href={crumb.href} prefetch={linkPrefetch(crumb.href)}>
                  {crumb.label}
                </Link>
              )}
            </li>
          ))}
        </ol>
      </nav>
      <JsonLd
        data={{
          '@type': 'BreadcrumbList',
          itemListElement: trail.map((crumb, index) => ({
            '@type': 'ListItem',
            position: index + 1,
            name: crumb.label,
            item: absoluteUrl(crumb.href)
          }))
        }}
      />
    </>
  )
}
