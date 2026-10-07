import { readdirSync, readFileSync } from 'node:fs'
import { join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import { pricing, pricingIncludes } from './pricing'
import { LEGAL_UPDATED } from './site'

const src = fileURLToPath(new URL('..', import.meta.url))

function sourceFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const path = join(dir, entry.name)
    if (entry.isDirectory()) return sourceFiles(path)
    return /\.tsx?$/.test(entry.name) && !/\.test\.tsx?$/.test(entry.name) ? [path] : []
  })
}

function strings(value: unknown): string[] {
  if (typeof value === 'string') return [value]
  if (value && typeof value === 'object') return Object.values(value).flatMap(strings)
  return []
}

/** `word`, or its plural, standing alone: "1 mac" skips "m1 mac", and "one mac" skips "one machine". */
function wholeWord(word: string) {
  const escaped = word.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  return new RegExp(`(?<![\\p{L}\\p{N}])${escaped}s?(?![\\p{L}\\p{N}])`, 'u')
}

describe('pricing', () => {
  it('words the Macs a license covers for labels and sentences', () => {
    expect(pricing.macsLabel).toBe(`${pricing.macs} Mac${pricing.macs === 1 ? '' : 's'}`)
    expect(pricing.macsText).toBe(`${pricing.macsInWords} Mac${pricing.macs === 1 ? '' : 's'}`)
  })

  it('lists the guarantee and the license on the pricing card', () => {
    expect(pricingIncludes).toContain(pricing.guarantee)
    expect(pricingIncludes.some(item => item.includes(pricing.macsLabel))).toBe(true)
  })

  // Trying another price or model is an edit to pricing.ts alone.
  it('keeps prices and terms of sale out of every other file', () => {
    const written = [
      pricing.price,
      `${pricing.refundDays}-day`,
      `${pricing.refundDays} days`,
      pricing.macsText,
      pricing.macsLabel,
      `${pricing.macsInWords}-Mac`,
      'buy.polar.sh',
      ...(pricing.checkoutUrl ? [pricing.checkoutUrl] : []),
      // The one-time model's own words. Revisit them with the terms for any other model.
      'one-time',
      'one time',
      'subscription',
      'yours to keep',
      'future updates',
      ...strings(pricing.model)
    ].map(word => word.toLowerCase())
    // #269: /license/ is a (sensitive-url) page, so it moves with its own leak test.
    const allowed = new Set([
      'app/(sensitive-url)/license/page.tsx: one mac',
      // Polar's billing reason `subscription_create`, which the webhook reads; not copy.
      'lib/polar-webhook.ts: subscription'
    ])
    const pricingFile = join(src, 'lib', 'pricing.ts')
    const found = sourceFiles(src)
      .filter(file => file !== pricingFile)
      .flatMap(file => {
        const text = readFileSync(file, 'utf8').toLowerCase()
        return written
          .filter(word => wholeWord(word).test(text))
          .map(word => `${relative(src, file)}: ${word}`)
      })
    expect(found.filter(offender => !allowed.has(offender))).toEqual([])
    // An allowance that no longer matches is stale: delete it.
    expect([...allowed].filter(allowance => !found.includes(allowance))).toEqual([])
  })

  // The terms and refund policy show these. Changing one changes those pages, so updating the
  // pinned values here is the moment to move LEGAL_UPDATED.
  it('dates the legal pages with the terms of sale they show', () => {
    expect({
      LEGAL_UPDATED,
      macs: pricing.macs,
      macsInWords: pricing.macsInWords,
      refundDays: pricing.refundDays,
      guarantee: pricing.guarantee,
      terms: pricing.model.terms
    }).toEqual({
      LEGAL_UPDATED: 'October 7, 2026',
      macs: 1,
      macsInWords: 'one',
      refundDays: 30,
      guarantee: '30-day money-back guarantee',
      terms: 'A one-time license does not expire. It includes all future updates to Keybumps.'
    })
  })
})
