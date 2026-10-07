import { createHmac, randomBytes } from 'node:crypto'
import { afterEach, beforeEach, describe, expect, it, type MockInstance, vi } from 'vitest'
import { POST } from '@/app/api/webhooks/polar/route'
import { derivedClientId, type Ga4Config, ga4ConfigFromEnv } from './ga4-measurement-protocol'
import { handlePolarWebhook, type PolarWebhookEnv, verifyPolarSignature } from './polar-webhook'

// Fake values only. Secrets are made per run; the order and IDs are made up.
const standardKey = randomBytes(24)
const standardSecret = `whsec_${standardKey.toString('base64')}`
const legacySecret = 'whsec_polar-hmac-test-secret'
const apiSecret = 'test-api-secret'
const now = 1_760_000_000_000
const clientId = '1234567890.1700000000'

const ga4: Ga4Config = { measurementId: 'G-TEST123', apiSecret, validateOnly: false }

function order(overrides: Record<string, unknown> = {}) {
  return {
    id: 'order_test_0001',
    status: 'paid',
    billing_reason: 'purchase',
    subtotal_amount: 4900,
    discount_amount: 1000,
    net_amount: 3900,
    tax_amount: 390,
    total_amount: 4290,
    refunded_amount: 0,
    currency: 'usd',
    billing_name: 'Test Buyer',
    billing_address: { country: 'US', line1: '1 Test Street' },
    customer: { email: 'buyer@example.com', name: 'Test Buyer' },
    product_id: 'prod_test',
    product: { name: 'Keybumps' },
    discount: { code: 'LAUNCH' },
    metadata: { reference_id: `ga=${clientId}&gs=1700000100` },
    ...overrides
  }
}

function sign(body: string, key: Buffer | string, id = 'msg_test_1', at = now) {
  const timestamp = String(Math.floor(at / 1000))
  const signature = createHmac('sha256', key).update(`${id}.${timestamp}.${body}`).digest('base64')
  return {
    'webhook-id': id,
    'webhook-timestamp': timestamp,
    'webhook-signature': `v1,${signature}`
  }
}

function delivery(type: string, data: unknown, key: Buffer | string = standardKey) {
  const body = JSON.stringify({ type, timestamp: new Date(now).toISOString(), data })
  return new Request('https://keybumps.app/api/webhooks/polar/', {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...sign(body, key) },
    body
  })
}

let logs: MockInstance<typeof console.log>
let sent: {
  url: URL
  body: { client_id: string; events: { name: string; params: Record<string, unknown> }[] }
}[]

function fakeFetch(response: () => Response | Promise<Response> = () => new Response(null)) {
  return (async (url: URL, init: RequestInit) => {
    sent.push({ url: new URL(url), body: JSON.parse(String(init.body)) })
    return response()
  }) as typeof fetch
}

function env(overrides: Partial<PolarWebhookEnv> = {}): PolarWebhookEnv {
  return { secret: standardSecret, ga4, fetch: fakeFetch(), now, ...overrides }
}

function logged() {
  return logs.mock.calls.map(call => JSON.parse(String(call[0])))
}

beforeEach(() => {
  sent = []
  logs = vi.spyOn(console, 'log').mockImplementation(() => {})
})

afterEach(() => {
  logs.mockRestore()
})

describe('Polar webhook signatures (#363)', () => {
  it('accepts a Standard Webhooks secret and an older Polar HMAC secret', async () => {
    const body = '{"type":"order.paid"}'
    const headers = (key: Buffer | string) => new Headers(sign(body, key))
    expect(await verifyPolarSignature(body, headers(standardKey), standardSecret, now)).toBeNull()
    expect(await verifyPolarSignature(body, headers(legacySecret), legacySecret, now)).toBeNull()
  })

  it('accepts any one valid signature in the header, as during a secret rotation', async () => {
    const body = '{"type":"order.paid"}'
    const valid = new Headers(sign(body, standardKey))
    const other = new Headers(sign(body, randomBytes(24)))
    const both = `${other.get('webhook-signature')} ${valid.get('webhook-signature')}`
    valid.set('webhook-signature', both)
    expect(await verifyPolarSignature(body, valid, standardSecret, now)).toBeNull()
    valid.set('webhook-signature', `v2,abc ${other.get('webhook-signature')}`)
    expect(await verifyPolarSignature(body, valid, standardSecret, now)).toBe('bad_signature')
  })

  it('accepts an older secret whose text also reads as base64', async () => {
    // "whsec_" plus 32 base64 characters: tried as a Standard Webhooks key first, then as text.
    const secret = `whsec_${'A'.repeat(32)}`
    const body = '{"type":"order.paid"}'
    expect(
      await verifyPolarSignature(body, new Headers(sign(body, secret)), secret, now)
    ).toBeNull()
  })

  it('rejects a wrong key, a changed body, missing headers, and an old or future timestamp', async () => {
    const body = '{"type":"order.paid"}'
    const headers = new Headers(sign(body, standardKey))
    expect(await verifyPolarSignature(body, headers, legacySecret, now)).toBe('bad_signature')
    expect(await verifyPolarSignature(`${body} `, headers, standardSecret, now)).toBe(
      'bad_signature'
    )
    expect(await verifyPolarSignature(body, new Headers(), standardSecret, now)).toBe(
      'missing_headers'
    )
    const sixMinutes = 6 * 60 * 1000
    // A replay of an old delivery, and a timestamp from the future.
    expect(await verifyPolarSignature(body, headers, standardSecret, now + sixMinutes)).toBe(
      'stale_timestamp'
    )
    expect(await verifyPolarSignature(body, headers, standardSecret, now - sixMinutes)).toBe(
      'stale_timestamp'
    )
  })

  it('answers 401 to a bad signature and sends nothing', async () => {
    const response = await handlePolarWebhook(
      delivery('order.paid', order(), randomBytes(24)),
      env()
    )
    expect(response.status).toBe(401)
    expect(sent).toEqual([])
    expect(logged()).toEqual([{ event: 'polar_webhook', status: 401, outcome: 'bad_signature' }])
  })

  it('answers 400 to a signed body that isn’t JSON', async () => {
    const body = 'not json'
    const request = new Request('https://keybumps.app/api/webhooks/polar/', {
      method: 'POST',
      headers: sign(body, standardKey),
      body
    })
    expect((await handlePolarWebhook(request, env())).status).toBe(400)
    expect(logged()).toEqual([{ event: 'polar_webhook', status: 400, outcome: 'bad_json' }])
  })

  it('answers 503 until the secret is set, so Polar retries', async () => {
    const response = await handlePolarWebhook(delivery('order.paid', order()), env({ secret: '' }))
    expect(response.status).toBe(503)
    expect(sent).toEqual([])
  })

  it('serves the route from the Worker’s secrets', async () => {
    vi.stubEnv('POLAR_WEBHOOK_SECRET', '')
    expect((await POST(delivery('order.paid', order()))).status).toBe(503)
    vi.unstubAllEnvs()
  })
})

describe('Polar orders to GA4 (#363)', () => {
  it('sends a paid order as a purchase with the real amount, order ID, and visit', async () => {
    const response = await handlePolarWebhook(delivery('order.paid', order()), env())
    expect(response.status).toBe(202)
    expect(sent).toHaveLength(1)
    const [{ url, body }] = sent
    expect(`${url.origin}${url.pathname}`).toBe('https://www.google-analytics.com/mp/collect')
    expect(url.searchParams.get('measurement_id')).toBe('G-TEST123')
    expect(url.searchParams.get('api_secret')).toBe(apiSecret)
    expect(body).toEqual({
      client_id: clientId,
      events: [
        {
          name: 'purchase',
          params: {
            transaction_id: 'order_test_0001',
            value: 39,
            currency: 'USD',
            tax: 3.9,
            coupon: 'LAUNCH',
            session_id: '1700000100',
            items: [{ item_id: 'prod_test', item_name: 'Keybumps', price: 39, quantity: 1 }]
          }
        }
      ]
    })
  })

  it('never sends the buyer’s name, email, or address', async () => {
    await handlePolarWebhook(delivery('order.paid', order()), env())
    const payload = JSON.stringify(sent[0].body)
    for (const personal of ['buyer@example.com', 'Test Buyer', '1 Test Street']) {
      expect(payload).not.toContain(personal)
    }
  })

  it('counts a buyer without a visit under a client ID derived from the order', async () => {
    const data = order({ metadata: {} })
    await handlePolarWebhook(delivery('order.paid', data), env())
    // A retried delivery gives the same client, so Google Analytics drops the repeat.
    await handlePolarWebhook(delivery('order.paid', data), env())
    const derived = await derivedClientId('order_test_0001')
    expect(derived).toMatch(/^\d+\.\d+$/)
    expect(sent.map(({ body }) => body.client_id)).toEqual([derived, derived])
    expect(sent[0].body.events[0].params.session_id).toBeUndefined()
  })

  it('sends nothing for a buyer who must choose cookies first and brought no visit', async () => {
    for (const country of ['DE', 'GB', 'CH']) {
      const data = order({ metadata: {}, billing_address: { country } })
      expect((await handlePolarWebhook(delivery('order.paid', data), env())).status).toBe(202)
    }
    const noCountry = order({ metadata: {}, billing_address: null })
    await handlePolarWebhook(delivery('order.paid', noCountry), env())
    expect(sent).toEqual([])
    expect(logged().map(line => line.ga4)).toEqual([
      'no_consent',
      'no_consent',
      'no_consent',
      'no_consent'
    ])
  })

  it('sends nothing for a buyer whose visit refused analytics, wherever they’re billed', async () => {
    const data = order({ metadata: { reference_id: 'consent=denied' } })
    await handlePolarWebhook(delivery('order.paid', data), env())
    const refund = order({
      status: 'refunded',
      refunded_amount: 3900,
      metadata: { reference_id: 'consent=denied' }
    })
    await handlePolarWebhook(delivery('order.refunded', refund), env())
    expect(sent).toEqual([])
    expect(logged().map(line => line.ga4)).toEqual(['no_consent', 'no_consent'])
  })

  it('sends a purchase for a buyer from those countries who allowed analytics', async () => {
    await handlePolarWebhook(
      delivery('order.paid', order({ billing_address: { country: 'DE' } })),
      env()
    )
    expect(sent[0].body.client_id).toBe(clientId)
  })

  it('credits a renewal to the client but not to the old session', async () => {
    await handlePolarWebhook(
      delivery('order.paid', order({ billing_reason: 'subscription_cycle' })),
      env()
    )
    expect(sent[0].body.client_id).toBe(clientId)
    expect(sent[0].body.events[0].params.session_id).toBeUndefined()
  })

  it('skips free orders', async () => {
    await handlePolarWebhook(delivery('order.paid', order({ net_amount: 0 })), env())
    expect(sent).toEqual([])
    expect(logged()[0].ga4).toBe('zero_amount')
  })

  it('sends a full refund, and leaves a partial one for a person', async () => {
    const refunded = order({ status: 'refunded', refunded_amount: 3900 })
    await handlePolarWebhook(delivery('order.refunded', refunded), env())
    expect(sent.map(({ body }) => body)).toEqual([
      {
        client_id: clientId,
        events: [
          {
            name: 'refund',
            params: { transaction_id: 'order_test_0001', value: 39, currency: 'USD' }
          }
        ]
      }
    ])
    const partial = order({ status: 'partially_refunded', refunded_amount: 1000 })
    await handlePolarWebhook(delivery('order.refunded', partial), env())
    expect(sent).toHaveLength(1)
    expect(logged()[1].ga4).toBe('partial_refund')
  })

  it('sends no refund for a buyer who must choose cookies first and brought no visit', async () => {
    const refunded = order({
      status: 'refunded',
      refunded_amount: 3900,
      metadata: {},
      billing_address: { country: 'FR' }
    })
    await handlePolarWebhook(delivery('order.refunded', refunded), env())
    expect(sent).toEqual([])
    expect(logged()[0].ga4).toBe('no_consent')
  })

  it('accepts other events without sending anything', async () => {
    for (const type of ['order.created', 'checkout.updated', 'subscription.active']) {
      expect((await handlePolarWebhook(delivery(type, order()), env())).status).toBe(202)
    }
    expect(sent).toEqual([])
    expect(logged().map(line => line.outcome)).toEqual(['ignored', 'ignored', 'ignored'])
  })

  it('accepts a malformed order without sending, and logs it', async () => {
    const response = await handlePolarWebhook(
      delivery('order.paid', order({ net_amount: '39.00' })),
      env()
    )
    expect(response.status).toBe(202)
    expect(sent).toEqual([])
    expect(logged()[0].outcome).toBe('unexpected_payload')
  })

  it('answers 502 when GA4 can’t be reached or refuses, so Polar retries', async () => {
    const down = env({
      fetch: fakeFetch(() => {
        throw new TypeError('network')
      })
    })
    expect((await handlePolarWebhook(delivery('order.paid', order()), down)).status).toBe(502)
    const refused = env({ fetch: fakeFetch(() => new Response(null, { status: 500 })) })
    expect((await handlePolarWebhook(delivery('order.paid', order()), refused)).status).toBe(502)
    expect(logged().map(line => line.ga4)).toEqual(['failed_network', 'failed_status'])
  })

  it('doesn’t retry a request GA4 rejects, which a retry wouldn’t change', async () => {
    const rejected = env({ fetch: fakeFetch(() => new Response(null, { status: 400 })) })
    expect((await handlePolarWebhook(delivery('order.paid', order()), rejected)).status).toBe(202)
    expect(logged()[0].ga4).toBe('rejected')
  })

  it('accepts deliveries before GA4 is set up, and sends nothing', async () => {
    const response = await handlePolarWebhook(delivery('order.paid', order()), env({ ga4: null }))
    expect(response.status).toBe(202)
    expect(sent).toEqual([])
    expect(logged()[0].ga4).toBe('not_configured')
  })

  it('only validates off the live site, and logs a validation message without retrying', async () => {
    const staging = { ...ga4, validateOnly: true }
    const valid = env({
      ga4: staging,
      fetch: fakeFetch(() => Response.json({ validationMessages: [] }))
    })
    expect((await handlePolarWebhook(delivery('order.paid', order()), valid)).status).toBe(202)
    expect(sent[0].url.pathname).toBe('/debug/mp/collect')
    const invalid = env({
      ga4: staging,
      fetch: fakeFetch(() => Response.json({ validationMessages: [{ description: 'bad' }] }))
    })
    expect((await handlePolarWebhook(delivery('order.paid', order()), invalid)).status).toBe(202)
    expect(logged().map(line => line.ga4)).toEqual(['sent', 'invalid'])
  })

  it('logs only the event type and outcomes', async () => {
    await handlePolarWebhook(delivery('order.paid', order()), env())
    await handlePolarWebhook(delivery('order.paid', order(), randomBytes(24)), env())
    const lines = logs.mock.calls.map(call => String(call[0]))
    for (const line of lines) {
      for (const secret of [
        'order_test_0001',
        clientId,
        '1700000100',
        'buyer@example.com',
        'prod_test',
        'LAUNCH',
        apiSecret,
        standardSecret,
        'msg_test_1'
      ]) {
        expect(line).not.toContain(secret)
      }
    }
    expect(logged()).toEqual([
      { event: 'polar_webhook', status: 202, type: 'order.paid', outcome: 'handled', ga4: 'sent' },
      { event: 'polar_webhook', status: 401, outcome: 'bad_signature' }
    ])
  })

  it('reads GA4’s config from the environment, validating off the live site', () => {
    const base = { GA4_MEASUREMENT_ID: 'G-TEST123', GA4_API_SECRET: apiSecret }
    expect(ga4ConfigFromEnv({ ...base, SITE_ENV: 'production' })).toEqual(ga4)
    expect(ga4ConfigFromEnv({ ...base, SITE_ENV: 'staging' })?.validateOnly).toBe(true)
    expect(ga4ConfigFromEnv({ ...base })?.validateOnly).toBe(true)
    expect(ga4ConfigFromEnv({ GA4_MEASUREMENT_ID: 'G-TEST123' })).toBeNull()
    expect(ga4ConfigFromEnv({ ...base, GA4_MEASUREMENT_ID: 'UA-1-1' })).toBeNull()
  })
})
