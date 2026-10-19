/**
 * What Keybumps costs and what a purchase includes: the one place to change when trying a different
 * price or pricing model. The pricing card, the home page's pricing section, /pricing/, the page
 * descriptions, and the terms and refund policy all read from here, and `pricing.test.ts` fails if
 * any of it is written out anywhere else. One exception so far: /license/ still says "one Mac"
 * (#269).
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

const numberWords = ['zero', 'one', 'two', 'three', 'four', 'five']
/** "one", for sentences. */
const macsInWords = numberWords[macs] ?? String(macs)
const plural = macs === 1 ? '' : 's'
/** "one Mac", for sentences. */
const macsText = `${macsInWords} Mac${plural}`

export const pricing = {
  price,
  renewalPrice,
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
  /** What a license covers and what it doesn't, on the terms and /pricing/ (#547). */
  scope:
    'The license covers the Keybumps features that run on your Mac. Online services that run on our servers, such as AI or cloud features, are not included; if we offer them, they are sold separately.',
  /** Everything that depends on how Keybumps is sold. */
  model: {
    /** The pricing card's pill. */
    label: 'One-time purchase',
    /** The home page pricing section's headline. */
    headline: 'One price. Yours to keep.',
    /** Under the home page pricing headline, before the guarantee. */
    summary: 'Pay once. A year of updates included.',
    /** Under /pricing/'s headline. */
    pageLede: 'Pay once and keep it. A year of updates and new plugins included.',
    /** On the pricing card's list. */
    updates: '1 year of updates, including new plugins',
    /** On the pricing card's list, after `updates`. */
    renewal: `Then ${renewalPrice}/year for updates, or keep the version you have`,
    /** /pricing/'s first question. */
    question: {
      q: 'Is this a subscription?',
      a: `No. You pay ${price} once, and that includes a year of updates and new plugins. After that, updates are ${renewalPrice} a year. If you don’t renew, the version you have is yours to keep and keeps working.`
    },
    /** /pricing/'s description, before the guarantee. */
    description: `Keybumps is a ${price} one-time purchase for ${macsText}, including a year of updates`,
    /** Terms § 3, after the grant: how long the license lasts and what it includes. */
    terms: `A license does not expire. It includes the updates released in the year after purchase, new plugins among them. When that year ends you may keep using the last version released in it, or renew updates for another year (currently ${renewalPrice} a year). Licenses bought before October 19, 2026 include the updates released through October 19, 2027.`
  }
} as const

/** The pricing card's list. */
export const pricingIncludes = [
  'Every plugin that runs on your Mac',
  `License for ${pricing.macsLabel} — move it to a new Mac any time`,
  pricing.model.updates,
  pricing.model.renewal,
  'No account and no cloud sync',
  pricing.guarantee
]
