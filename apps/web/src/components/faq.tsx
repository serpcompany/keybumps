import { JsonLd } from '@/components/json-ld'

export type Question = { q: string; a: string }

/** Questions and answers that open in place, with their FAQPage data. */
export function Faq({ questions }: { questions: readonly Question[] }) {
  return (
    <>
      <div className="faq">
        {questions.map(item => (
          <details key={item.q}>
            <summary>{item.q}</summary>
            <p>{item.a}</p>
          </details>
        ))}
      </div>
      <JsonLd
        data={{
          '@type': 'FAQPage',
          mainEntity: questions.map(item => ({
            '@type': 'Question',
            name: item.q,
            acceptedAnswer: { '@type': 'Answer', text: item.a }
          }))
        }}
      />
    </>
  )
}
