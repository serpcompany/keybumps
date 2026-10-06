/**
 * What Keybumps costs and what a purchase includes: the one place to change when trying a different
 * price or pricing model. The pricing card, the home page's pricing section, /pricing/, the page
 * descriptions, and the terms, refund policy, and privacy policy all read from here, and
 * `pricing.test.ts` fails if any of it is written out anywhere else.
 *
 * Terms of sale: `macs`, `macsInWords`, `refundDays`, `guarantee`, and `model.terms` appear on the
 * legal pages, so changing one changes them. `pricing.test.ts` pins these with `LEGAL_UPDATED` (in
 * ./site), so it fails until the date moves too. A model with renewals, such as a subscription,
 * also needs new terms written for it: renewal, cancellation, and what happens when it lapses.
 */

const price = '$49'
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
  /** Everything that depends on how Keybumps is sold. */
  model: {
    /** The pricing card's pill. */
    label: 'One-time purchase',
    /** The home page pricing section's headline. */
    headline: 'One price. Yours to keep.',
    /** Under the home page pricing headline, before the guarantee. */
    summary: 'No subscription, no account.',
    /** Under /pricing/'s headline. */
    pageLede: 'One app, one price. No subscription, no account.',
    /** On the pricing card's list. */
    updates: 'All future updates included',
    /** /pricing/'s first question. */
    question: {
      q: 'Is this a subscription?',
      a: `No. You pay ${price} once and the license is yours to keep. It includes all future updates.`
    },
    /** /pricing/'s description, before the guarantee. */
    description: `Keybumps is a ${price} one-time purchase for ${macsText}`,
    /** Terms § 3, after the grant: how long the license lasts and what it includes. */
    terms: 'A one-time license does not expire. It includes all future updates to Keybumps.'
  }
} as const

/** The pricing card's list. */
export const pricingIncludes = [
  'Every plugin',
  `License for ${pricing.macsLabel} — move it to a new Mac any time`,
  pricing.model.updates,
  'No account and no cloud sync',
  pricing.guarantee
]
