import { describe, expect, it } from 'vitest'
import { GET } from '@/app/buy/route'
import {
  buyRedirect,
  encodeCheckoutReference,
  gaClientIdFromCookie,
  gaSessionCookieName,
  gaSessionIdFromCookie,
  parseCheckoutReference,
  readCookie,
  referenceFromCookies
} from './checkout-reference'
import { pricing } from './pricing'

// Fake IDs in the formats Google Analytics writes.
const gaCookie = '_ga=GA1.1.1234567890.1700000000'
const sessionV1 = '_ga_TEST123=GS1.1.1700000100.3.1.1700000200.0.0.0'
const sessionV2 = '_ga_TEST123=GS2.1.s1700000100$o3$g1$t1700000200$j0$l0$h0'
const checkout = 'https://checkout.example/polar_cl_test'

describe('checkout reference (#363)', () => {
  it('reads the client ID from _ga and the session ID from either _ga_<stream> format', () => {
    expect(gaClientIdFromCookie('GA1.1.1234567890.1700000000')).toBe('1234567890.1700000000')
    expect(gaClientIdFromCookie('GA1.2.42.1700000000')).toBe('42.1700000000')
    for (const bad of [undefined, '', 'GA1.1.abc.1700000000', '1234567890.1700000000']) {
      expect(gaClientIdFromCookie(bad), String(bad)).toBeUndefined()
    }
    expect(gaSessionIdFromCookie('GS1.1.1700000100.3.1.1700000200.0.0.0')).toBe('1700000100')
    expect(gaSessionIdFromCookie('GS2.1.s1700000100$o3$g1$t1700000200$j0$l0$h0')).toBe('1700000100')
    expect(gaSessionIdFromCookie('GS3.1.x')).toBeUndefined()
    expect(gaSessionCookieName('G-TEST123')).toBe('_ga_TEST123')
    expect(gaSessionCookieName('UA-1234-1')).toBeUndefined()
    expect(gaSessionCookieName(undefined)).toBeUndefined()
  })

  it('reads one cookie from a Cookie header', () => {
    const header = `other=1; ${gaCookie}; ${sessionV2}`
    expect(readCookie(header, '_ga')).toBe('GA1.1.1234567890.1700000000')
    expect(readCookie(header, '_ga_TEST123')).toMatch(/^GS2\./)
    expect(readCookie(header, 'missing')).toBeUndefined()
    expect(readCookie(null, '_ga')).toBeUndefined()
  })

  it('builds a reference only from the analytics cookies', () => {
    expect(referenceFromCookies(`${gaCookie}; ${sessionV1}`, 'G-TEST123')).toEqual({
      gaClientId: '1234567890.1700000000',
      gaSessionId: '1700000100'
    })
    expect(referenceFromCookies(gaCookie, undefined)).toEqual({
      gaClientId: '1234567890.1700000000'
    })
    // No client ID (analytics declined or blocked): nothing, not even the session.
    expect(referenceFromCookies(sessionV1, 'G-TEST123')).toEqual({})
    expect(referenceFromCookies(null, 'G-TEST123')).toEqual({})
  })

  it('round-trips through Polar, and drops anything /buy/ would not write', () => {
    const reference = { gaClientId: '1234567890.1700000000', gaSessionId: '1700000100' }
    const encoded = encodeCheckoutReference(reference)
    expect(encoded).toBe('ga=1234567890.1700000000&gs=1700000100')
    expect(parseCheckoutReference(encoded)).toEqual(reference)
    expect(encodeCheckoutReference({})).toBeNull()
    for (const forged of [
      'ga=1234567890.1700000000<script>',
      'ga=me@example.com',
      'gs=1700000100',
      `ga=1.2&gs=${'9'.repeat(600)}`,
      42,
      null
    ]) {
      expect(parseCheckoutReference(forged), String(forged)).toEqual({})
    }
    expect(parseCheckoutReference('ga=1.2&gs=bad')).toEqual({ gaClientId: '1.2' })
  })

  it('/buy/ redirects to the checkout with the reference, uncached', () => {
    const response = buyRedirect(`${gaCookie}; ${sessionV2}`, 'G-TEST123', checkout)
    expect(response.status).toBe(302)
    expect(response.headers.get('cache-control')).toBe('private, no-store')
    const location = new URL(response.headers.get('location') ?? '')
    expect(`${location.origin}${location.pathname}`).toBe(checkout)
    expect(location.searchParams.get('reference_id')).toBe('ga=1234567890.1700000000&gs=1700000100')
  })

  it('/buy/ sends a visitor without analytics cookies to the bare checkout', () => {
    const response = buyRedirect('other=1', 'G-TEST123', checkout)
    expect(response.headers.get('location')).toBe(checkout)
  })

  it('/buy/ goes to /pricing/ when there is no checkout', () => {
    expect(buyRedirect(gaCookie, 'G-TEST123', null).headers.get('location')).toBe('/pricing/')
  })

  it('serves /buy/ from the pricing checkout link', () => {
    const response = GET(new Request('https://keybumps.app/buy/'))
    const expected = pricing.checkoutUrl ?? '/pricing/'
    expect(response.headers.get('location')).toBe(expected)
  })
})
