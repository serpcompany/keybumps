/**
 * What Keybumps costs and what a purchase includes: the one place to change when trying a different
 * price or pricing model. The pricing card, /pricing/, the page descriptions, and the terms and
 * refund policy all read from here, and `pricing.test.ts` fails if any of it is written out
 * anywhere else. One exception so far: /license/ still says "one Mac" (#269).
 *
 * Terms of sale: `renewalPrice`, `macs`, `macsInWords`, `refundDays`, `guarantee`, `scope`, and
 * `model.terms` appear on the legal pages, so changing one changes them. `pricing.test.ts` pins these
 * values next to `LEGAL_UPDATED` (in ./site): it fails until the pinned values are updated, which is
 * the moment to move the date. Automatic renewal, once it's sold (#548), also needs terms written for
 * it: how it renews, how to cancel, and refunds of a renewal.
 */

const price = '$97'
/** What another year of updates costs once the first year ends. */
const renewalPrice = '$49'
/** Macs one license covers. */
const macs = 1
/** Days in which a purchase is refunded in full, no questions asked. */
const refundDays = 30
/** Licenses bought before the update year began (the day it went live)... */
const updateYearBegan = 'October 19, 2026'
/** ...get updates through this day, a year after it. */
const earlierLicensesUpdatedThrough = 'October 19, 2027'
/** What a license covers and what it doesn't, on the terms and /pricing/ (#547). */
const scope =
  'The license covers the Keybumps features that run on your Mac. Features that run on our servers, such as AI or cloud services, are not included; if we offer them, they are sold separately.'

const numberWords = ['zero', 'one', 'two', 'three', 'four', 'five']
/** "one", for sentences. */
const macsInWords = numberWords[macs] ?? String(macs)
const plural = macs === 1 ? '' : 's'
/** "one Mac", for sentences. */
const macsText = `${macsInWords} Mac${plural}`

export const pricing = {
  price,
  renewalPrice,
  updateYearBegan,
  earlierLicensesUpdatedThrough,
  /** After the price, such as "/month"; empty for a one-time purchase. */
  period: '',
  currency: 'USD',
  /** Polar's checkout for this price. When it's null, the buy button downloads the current DMG. */
  checkoutUrl: 'https://buy.polar.sh/polar_cl_NgKwENo1kvvLio6Xl27IFyoWpAoqf73sN8mRX03RNTj' as
    | string
    | null,
  /** The pricing card's button, before the price. */
  cta: 'Buy Keybumps',
  macs,
  macsInWords,
  refundDays,
  /** "1 Mac", for labels. */
  macsLabel: `${macs} Mac${plural}`,
  macsText,
  guarantee: `${refundDays}-day money-back guarantee`,
  scope,
  /** /pricing/'s second question. */
  scopeQuestion: { q: 'Does it include AI or cloud features?', a: `No. ${scope}` },
  /** Everything that depends on how Keybumps is sold. */
  model: {
    /** The pricing card's pill. */
    label: 'One-time purchase',
    /** Under /pricing/'s headline. */
    pageLede: 'Pay once and keep it. A year of updates and new plugins included.',
    /** On the pricing card's list. */
    updates: '1 year of updates, including new plugins',
    /** On the pricing card's list, after `updates`. */
    keep: 'Yours to keep, even if you don’t renew',
    /** The pricing card's fine print, before taxes. */
    renewal: `After the first year, updates are ${renewalPrice}/year. Renewing is optional.`,
    /** /pricing/'s first question. */
    question: {
      q: 'Do I have to renew?',
      a: `No. You pay ${price} once, and that includes a year of updates and new plugins. After that, renewing updates is optional, at ${renewalPrice} a year. If you don’t renew, Keybumps keeps working, and the last version released in your year of updates is yours to keep.`
    },
    /** /pricing/'s description, before the guarantee. */
    description: `Keybumps is a ${price} one-time purchase for ${macsText}, including a year of updates`,
    /** Terms § 3, after the grant: how long the license lasts and what it includes. */
    terms: `A license does not expire. It includes the updates released in the year after purchase, new plugins among them; a license bought before ${updateYearBegan} includes the updates released through ${earlierLicensesUpdatedThrough}. When a license’s updates end, you may keep using the last version released before then, or renew updates for another year (currently ${renewalPrice} a year).`
  }
} as const

/** The pricing card's list. */
export const pricingIncludes = [
  'Every plugin that runs on your Mac',
  `License for ${pricing.macsLabel} — move it to a new Mac any time`,
  pricing.model.updates,
  pricing.model.keep,
  'No account and no cloud sync',
  pricing.guarantee
]
