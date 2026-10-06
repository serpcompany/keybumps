import { readdirSync, readFileSync } from 'node:fs'
import { join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import { pricing, pricingIncludes } from './pricing'

const src = fileURLToPath(new URL('..', import.meta.url))

function sourceFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const path = join(dir, entry.name)
    if (entry.isDirectory()) return sourceFiles(path)
    return /\.tsx?$/.test(entry.name) && !/\.test\.tsx?$/.test(entry.name) ? [path] : []
  })
}

describe('pricing', () => {
  it('words the Macs a license covers for labels and sentences', () => {
    expect(pricing.macsLabel).toBe(`${pricing.macs} Mac${pricing.macs === 1 ? '' : 's'}`)
    expect(pricing.macsText.endsWith(pricing.macs === 1 ? ' Mac' : ' Macs')).toBe(true)
  })

  it('lists the guarantee and the license on the pricing card', () => {
    expect(pricingIncludes).toContain(pricing.guarantee)
    expect(pricingIncludes.some(item => item.includes(pricing.macsLabel))).toBe(true)
  })

  // Trying another price or model is an edit to pricing.ts alone.
  it('keeps the price and refund window out of every other file', () => {
    const written = [
      pricing.price,
      `${pricing.refundDays}-day`,
      `${pricing.refundDays} days`,
      'one-time',
      'One-time'
    ]
    const offenders = sourceFiles(src)
      .filter(file => !file.endsWith(join('lib', 'pricing.ts')))
      .flatMap(file => {
        const text = readFileSync(file, 'utf8')
        return written
          .filter(word => text.includes(word))
          .map(word => `${relative(src, file)}: ${word}`)
      })
    expect(offenders).toEqual([])
  })
})
