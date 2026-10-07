import { runInNewContext } from 'node:vm'
import { describe, expect, it } from 'vitest'
import { consentDefaults } from '@/components/analytics'

/**
 * Runs the inline consent script as a page would, with a fake window as its global object, and
 * returns what it did.
 */
function run(saved: string | null, { cookiesBlocked = false, storageBlocked = false } = {}) {
  const dataLayer: unknown[] = []
  const cookies: string[] = []
  const listeners: Record<string, (event: { detail: unknown }) => void> = {}
  const window: Record<string, unknown> = {
    dataLayer,
    localStorage: {
      getItem: () => {
        if (storageBlocked) throw new Error('storage blocked')
        return saved
      }
    },
    document: {
      set cookie(value: string) {
        if (cookiesBlocked) throw new Error('cookies blocked')
        cookies.push(value)
      }
    },
    addEventListener: (name: string, listener: (event: { detail: unknown }) => void) => {
      listeners[name] = listener
    }
  }
  window.window = window
  runInNewContext(consentDefaults, window)
  return {
    window,
    dataLayer,
    cookies,
    choose: (choice: string) => listeners['keybumps:consent']({ detail: choice })
  }
}

describe('the inline consent script (#337, #363)', () => {
  it('writes a saved choice to the consent cookie on every page view', () => {
    const { cookies } = run('granted')
    expect(cookies).toEqual([
      'keybumps-consent=granted;Max-Age=31536000;Path=/;SameSite=Lax;Secure'
    ])
  })

  it('deletes the cookie when no choice is saved, then writes the banner’s choice', () => {
    const page = run(null)
    // The banner will ask again, so /buy/ mustn't act on an older choice.
    expect(page.cookies).toEqual(['keybumps-consent=;Max-Age=0;Path=/;SameSite=Lax;Secure'])
    page.cookies.length = 0
    page.choose('denied')
    expect(page.cookies).toEqual([
      'keybumps-consent=denied;Max-Age=31536000;Path=/;SameSite=Lax;Secure'
    ])
    page.choose('something else')
    expect(page.cookies).toHaveLength(1)
  })

  it('deletes the cookie when storage can’t be read or holds something else', () => {
    const deleted = ['keybumps-consent=;Max-Age=0;Path=/;SameSite=Lax;Secure']
    expect(run(null, { storageBlocked: true }).cookies).toEqual(deleted)
    expect(run('yes').cookies).toEqual(deleted)
  })

  it('leaves no globals behind besides its own functions', () => {
    const page = run('granted')
    // Top-level declarations in an inline script become window properties, so nothing that holds
    // the visitor's choice may be declared there.
    expect(Object.keys(page.window).sort()).toEqual(
      [
        'addEventListener',
        'dataLayer',
        'document',
        'gtag',
        'keybumpsConsent',
        'localStorage',
        'window'
      ].sort()
    )
  })

  it('still updates consent and tells GTM when cookies can’t be written', () => {
    const page = run(null, { cookiesBlocked: true })
    page.choose('granted')
    const pushes = page.dataLayer.map(entry =>
      JSON.stringify(Array.from(entry as ArrayLike<unknown>))
    )
    expect(pushes.some(push => push.includes('"update"') && push.includes('"granted"'))).toBe(true)
    expect(page.dataLayer).toContainEqual({
      event: 'keybumps_consent',
      keybumps_consent: 'granted'
    })
  })
})
