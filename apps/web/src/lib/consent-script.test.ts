import { describe, expect, it } from 'vitest'
import { consentDefaults } from '@/components/analytics'

/** Runs the inline consent script against a fake page and returns what it did. */
function run(saved: string | null) {
  const dataLayer: unknown[] = []
  const cookies: string[] = []
  const listeners: Record<string, (event: { detail: unknown }) => void> = {}
  const window = {
    dataLayer,
    localStorage: { getItem: () => saved },
    document: {
      set cookie(value: string) {
        cookies.push(value)
      }
    },
    addEventListener: (name: string, listener: (event: { detail: unknown }) => void) => {
      listeners[name] = listener
    }
  }
  new Function('window', `with (window) { ${consentDefaults} }`)(window)
  return {
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

  it('writes the banner’s choice, and nothing before one is made', () => {
    const page = run(null)
    expect(page.cookies).toEqual([])
    page.choose('denied')
    expect(page.cookies).toEqual([
      'keybumps-consent=denied;Max-Age=31536000;Path=/;SameSite=Lax;Secure'
    ])
    page.choose('something else')
    expect(page.cookies).toHaveLength(1)
  })
})
