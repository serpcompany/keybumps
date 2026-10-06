/**
 * What Keybumps costs and what a purchase includes: the one place to change when trying a different
 * price or pricing model. The pricing card, the home page's pricing section, /pricing/, the page
 * descriptions, and the terms and refund policy all read from here.
 *
 * `macs`, `refundDays`, and `model.terms` are terms of sale: changing them changes the terms and
 * refund policy, so update `LEGAL_UPDATED` in ./site in the same change.
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
  currency: 'USD',
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
    /** Under the pricing headlines. */
    summary: 'No subscription, no account.',
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
