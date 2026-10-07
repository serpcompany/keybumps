import { describe, expect, it } from 'vitest'
import { GET } from '@/app/api/consent/route'
import { consentCountries, requiresConsent, storedConsent } from './consent'

describe('cookie consent (#337)', () => {
  it('asks visitors from the EU, the EEA, the UK, and Switzerland, and no one else', () => {
    for (const country of ['DE', 'FR', 'GR', 'IE', 'NO', 'IS', 'LI', 'GB', 'CH', 'de']) {
      expect(requiresConsent(country), country).toBe(true)
    }
    for (const country of ['US', 'JP', 'CA', 'AU', 'BR', 'IN', 'SG']) {
      expect(requiresConsent(country), country).toBe(false)
    }
    expect(consentCountries).toHaveLength(32)
  })

  it('asks when the country is unknown', () => {
    for (const country of [null, undefined, '', 'XX', 'T1']) {
      expect(requiresConsent(country), String(country)).toBe(true)
    }
  })

  it('reads only a real stored choice', () => {
    expect(storedConsent('granted')).toBe('granted')
    expect(storedConsent('denied')).toBe('denied')
    expect(storedConsent('yes')).toBeNull()
    expect(storedConsent(null)).toBeNull()
  })

  it('answers /api/consent/ from Cloudflare’s country, uncached, without echoing it', async () => {
    const ask = async (country?: string) => {
      const headers = country ? { 'cf-ipcountry': country } : undefined
      const response = await GET(new Request('https://keybumps.app/api/consent/', { headers }))
      return { body: await response.json(), cache: response.headers.get('cache-control') }
    }
    expect(await ask('DE')).toEqual({ body: { required: true }, cache: 'private, no-store' })
    expect(await ask('US')).toEqual({ body: { required: false }, cache: 'private, no-store' })
    expect((await ask()).body).toEqual({ required: true })
  })
})
