/**
 * Structured data for search engines, as a JSON-LD script. `<` is escaped so text in the data
 * can never close the script element.
 */
export function JsonLd({ data }: { data: Record<string, unknown> }) {
  const json = JSON.stringify({ '@context': 'https://schema.org', ...data }).replace(
    /</g,
    '\\u003c'
  )
  return (
    <script
      type="application/ld+json"
      // biome-ignore lint/security/noDangerouslySetInnerHtml: JSON-LD has to be the script's text; `<` is escaped above.
      dangerouslySetInnerHTML={{ __html: json }}
    />
  )
}
