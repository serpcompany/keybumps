import { createHmac, randomBytes } from 'node:crypto'
import { afterEach, beforeEach, describe, expect, it, type MockInstance, vi } from 'vitest'
import { POST } from '@/app/api/webhooks/polar/route'
import { type DubConfig, dubConfigFromEnv } from './dub-conversions'
import { derivedClientId, type Ga4Config, ga4ConfigFromEnv } from './ga4-measurement-protocol'
import { handlePolarWebhook, type PolarWebhookEnv, verifyPolarSignature } from './polar-webhook'

// Fake values only. Secrets are made per run; the order and IDs are made up.
const standardKey = randomBytes(24)
const standardSecret = `whsec_${standardKey.toString('base64')}`
const legacySecret = 'whsec_polar-hmac-test-secret'
const apiSecret = 'test-api-secret'
const now = 1_760_000_000_000
const clientId = '1234567890.1700000000'
const dubClickId = 'dubclicktest0001'
const dubApiKey = 'test-dub-api-key'

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
    customer_id: 'cus_test_0001',
    product_id: 'prod_test',
    product: { name: 'Keybumps' },
    discount: { code: 'LAUNCH' },
    metadata: { reference_id: `ga=${clientId}&gs=1700000100&dub=${dubClickId}` },
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
  return { secret: standardSecret, ga4, dub: null, fetch: fakeFetch(), now, ...overrides }
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
        'cus_test_0001',
        dubClickId,
        apiSecret,
        standardSecret,
        'msg_test_1'
      ]) {
        expect(line).not.toContain(secret)
      }
    }
    expect(logged()).toEqual([
      {
        event: 'polar_webhook',
        status: 202,
        type: 'order.paid',
        outcome: 'handled',
        ga4: 'sent',
        dub: 'not_configured'
      },
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

describe('Polar orders to Dub (#337)', () => {
  const dub: DubConfig = { apiKey: dubApiKey }
  interface Call {
    method: string
    url: URL
    headers: Headers
    body: unknown
  }
  let calls: Call[]

  /** A fake fetch that records each call and answers from `route`. */
  function router(
    route: (call: Call) => Response = () => Response.json({ customer: { id: 'c' } })
  ) {
    return (async (input: URL | string, init: RequestInit = {}) => {
      const call = {
        method: init.method ?? 'GET',
        url: new URL(String(input)),
        headers: new Headers(init.headers),
        body: init.body ? JSON.parse(String(init.body)) : undefined
      }
      calls.push(call)
      return route(call)
    }) as typeof fetch
  }

  function dubEnv(route?: (call: Call) => Response, overrides: Partial<PolarWebhookEnv> = {}) {
    return env({ ga4: null, dub, fetch: router(route), ...overrides })
  }

  beforeEach(() => {
    calls = []
  })

  it('tracks a paid order a partner link brought as a Dub sale', async () => {
    const response = await handlePolarWebhook(delivery('order.paid', order()), dubEnv())
    expect(response.status).toBe(202)
    expect(calls).toHaveLength(1)
    const [call] = calls
    expect(`${call.method} ${call.url}`).toBe('POST https://api.dub.co/track/sale')
    expect(call.headers.get('authorization')).toBe(`Bearer ${dubApiKey}`)
    expect(call.body).toEqual({
      clickId: dubClickId,
      customerExternalId: 'keybumps_cus_test_0001',
      amount: 3900,
      currency: 'usd',
      invoiceId: 'order_test_0001',
      eventName: 'Purchase',
      paymentProcessor: 'polar'
    })
    expect(JSON.stringify(call.body)).not.toMatch(/buyer@example\.com|Test Buyer|Test Street/)
    expect(logged()[0]).toMatchObject({ dub: 'sent', ga4: 'not_configured' })
  })

  it('names a renewal so partners can tell it from a purchase', async () => {
    await handlePolarWebhook(
      delivery('order.paid', order({ billing_reason: 'subscription_cycle' })),
      dubEnv()
    )
    expect(calls[0].body).toMatchObject({ eventName: 'Invoice paid', clickId: dubClickId })
  })

  it('sends nothing to Dub without a partner click', async () => {
    const data = order({ metadata: { reference_id: `ga=${clientId}` } })
    await handlePolarWebhook(delivery('order.paid', data), dubEnv())
    await handlePolarWebhook(delivery('order.paid', order({ net_amount: 0 })), dubEnv())
    expect(calls).toEqual([])
    expect(logged().map(line => line.dub)).toEqual(['no_click', 'zero_amount'])
  })

  it('logs a click Dub doesn’t know (a 404) as unattributed, without retrying', async () => {
    const response = await handlePolarWebhook(
      delivery('order.paid', order()),
      dubEnv(() => Response.json({ error: { code: 'not_found' } }, { status: 404 }))
    )
    expect(response.status).toBe(202)
    expect(logged()[0].dub).toBe('unattributed')
  })

  it('names a first subscription payment, and skips an unpaid or customerless order', async () => {
    await handlePolarWebhook(
      delivery('order.paid', order({ billing_reason: 'subscription_create' })),
      dubEnv()
    )
    expect(calls[0].body).toMatchObject({ eventName: 'Subscription created' })
    await handlePolarWebhook(delivery('order.paid', order({ status: 'pending' })), dubEnv())
    await handlePolarWebhook(delivery('order.paid', order({ customer_id: null })), dubEnv())
    expect(calls).toHaveLength(1)
    expect(logged().map(line => line.dub)).toEqual(['sent', 'not_paid', 'no_customer'])
  })

  it('retries when Dub is down or the key is refused, and not when Dub refuses the sale', async () => {
    const statuses = [500, 429, 401, 403, 400, 422]
    for (const status of statuses) {
      const response = await handlePolarWebhook(
        delivery('order.paid', order()),
        dubEnv(() => new Response(null, { status }))
      )
      expect(response.status, String(status)).toBe(status === 400 || status === 422 ? 202 : 502)
    }
    const offline = dubEnv(() => {
      throw new TypeError('network')
    })
    expect((await handlePolarWebhook(delivery('order.paid', order()), offline)).status).toBe(502)
    expect(logged().map(line => line.dub)).toEqual([
      'failed_status',
      'failed_status',
      'failed_auth',
      'failed_auth',
      'rejected',
      'rejected',
      'failed_network'
    ])
  })

  it('retries when GA4 fails even though Dub took the sale, which Dub keeps once', async () => {
    const both = env({
      dub,
      fetch: router(call =>
        call.url.hostname === 'www.google-analytics.com'
          ? new Response(null, { status: 503 })
          : Response.json({ customer: { id: 'c' } })
      )
    })
    expect((await handlePolarWebhook(delivery('order.paid', order()), both)).status).toBe(502)
    expect(logged()[0]).toMatchObject({ ga4: 'failed_status', dub: 'sent' })
  })

  it('sends both again on the retry after a GA4 failure, with the same IDs', async () => {
    let ga4Down = true
    const flaky = env({
      dub,
      fetch: router(call =>
        call.url.hostname === 'www.google-analytics.com' && ga4Down
          ? new Response(null, { status: 503 })
          : Response.json({ customer: { id: 'c' } })
      )
    })
    expect((await handlePolarWebhook(delivery('order.paid', order()), flaky)).status).toBe(502)
    ga4Down = false
    expect((await handlePolarWebhook(delivery('order.paid', order()), flaky)).status).toBe(202)
    const dubCalls = calls.filter(call => call.url.hostname === 'api.dub.co')
    const ga4Calls = calls.filter(call => call.url.hostname === 'www.google-analytics.com')
    expect(dubCalls.map(call => (call.body as { invoiceId: string }).invoiceId)).toEqual([
      'order_test_0001',
      'order_test_0001'
    ])
    expect(ga4Calls.map(call => (call.body as { client_id: string }).client_id)).toEqual([
      clientId,
      clientId
    ])
  })

  it('refunds in Dub first, and sends GA4 its refund only once Dub has it', async () => {
    const refunded = () =>
      delivery('order.refunded', order({ status: 'refunded', refunded_amount: 3900 }))
    let dubDown = true
    const both = env({
      dub,
      fetch: router(call => {
        if (call.url.hostname === 'www.google-analytics.com') return new Response(null)
        if (dubDown) return new Response(null, { status: 503 })
        return call.method === 'GET'
          ? Response.json([{ id: 'cm_test_1', status: 'pending' }])
          : Response.json({})
      })
    })
    expect((await handlePolarWebhook(refunded(), both)).status).toBe(502)
    expect(calls.some(call => call.url.hostname === 'www.google-analytics.com')).toBe(false)
    dubDown = false
    expect((await handlePolarWebhook(refunded(), both)).status).toBe(202)
    const ga4Refunds = calls.filter(call => call.url.hostname === 'www.google-analytics.com')
    expect(ga4Refunds).toHaveLength(1)
    expect(logged().map(line => `${line.dub} ${line.ga4}`)).toEqual([
      'failed_status deferred',
      'refunded sent'
    ])
  })

  it('refunds the partner’s commission when the order is fully refunded', async () => {
    const refunded = delivery(
      'order.refunded',
      order({ status: 'refunded', refunded_amount: 3900 })
    )
    const response = await handlePolarWebhook(
      refunded,
      dubEnv(call =>
        call.method === 'GET'
          ? Response.json([{ id: 'cm_test_1', status: 'pending' }])
          : Response.json({ id: 'cm_test_1', status: 'refunded' })
      )
    )
    expect(response.status).toBe(202)
    expect(calls.map(call => `${call.method} ${call.url}`)).toEqual([
      'GET https://api.dub.co/commissions?invoiceId=order_test_0001',
      'PATCH https://api.dub.co/commissions/cm_test_1'
    ])
    expect(calls[1].body).toEqual({ status: 'refunded' })
    expect(logged()[0].dub).toBe('refunded')
  })

  it('refunds a pending, held, or not-yet-sent commission', async () => {
    const refunded = () =>
      delivery('order.refunded', order({ status: 'refunded', refunded_amount: 3900 }))
    for (const status of ['pending', 'hold', 'processed']) {
      await handlePolarWebhook(
        refunded(),
        dubEnv(call =>
          call.method === 'GET' ? Response.json([{ id: 'cm_test_1', status }]) : Response.json({})
        )
      )
    }
    expect(calls.filter(call => call.method === 'PATCH')).toHaveLength(3)
    expect(logged().map(line => line.dub)).toEqual(['refunded', 'refunded', 'refunded'])
  })

  it('reports a commission whose payout is already being sent as paid', async () => {
    await handlePolarWebhook(
      delivery('order.refunded', order({ status: 'refunded', refunded_amount: 3900 })),
      dubEnv(call =>
        call.method === 'GET'
          ? Response.json([{ id: 'cm_test_1', status: 'processed' }])
          : Response.json({ error: { code: 'bad_request' } }, { status: 400 })
      )
    )
    expect(logged()[0]).toMatchObject({ status: 202, dub: 'already_paid' })
  })

  it('leaves a paid, refunded, closed, or missing commission alone', async () => {
    const refunded = () =>
      delivery('order.refunded', order({ status: 'refunded', refunded_amount: 3900 }))
    for (const listed of [
      [{ id: 'cm_test_1', status: 'paid' }],
      [{ id: 'cm_test_1', status: 'refunded' }],
      [{ id: 'cm_test_1', status: 'duplicate' }],
      [{ id: 'cm_test_1', status: 'fraud' }],
      [{ id: 'cm_test_1', status: 'canceled' }],
      [{ id: 'cm_test_1', status: 'some_new_status' }],
      []
    ]) {
      await handlePolarWebhook(
        refunded(),
        dubEnv(() => Response.json(listed))
      )
    }
    expect(calls.every(call => call.method === 'GET')).toBe(true)
    expect(logged().map(line => line.dub)).toEqual([
      'already_paid',
      'refunded',
      'closed',
      'closed',
      'closed',
      'closed',
      'no_commission'
    ])
  })

  it('logs a refused PATCH: rejected when pending, no_commission on a 404', async () => {
    const refunded = () =>
      delivery('order.refunded', order({ status: 'refunded', refunded_amount: 3900 }))
    for (const [status, code] of [
      ['pending', 400],
      ['processed', 404]
    ] as const) {
      await handlePolarWebhook(
        refunded(),
        dubEnv(call =>
          call.method === 'GET'
            ? Response.json([{ id: 'cm_test_1', status }])
            : new Response(null, { status: code })
        )
      )
    }
    expect(logged().map(line => line.dub)).toEqual(['rejected', 'no_commission'])
  })

  it('never raises a sale a later partial refund already lowered', async () => {
    // A retried older event (1000 refunded, so 2900 left) after a later one set the sale to 1900.
    const older = order({ status: 'partially_refunded', refunded_amount: 1000 })
    await handlePolarWebhook(
      delivery('order.refunded', older),
      dubEnv(call =>
        call.method === 'GET'
          ? Response.json([{ id: 'cm_test_1', status: 'pending', amount: 1900 }])
          : Response.json({})
      )
    )
    expect(calls.map(call => call.method)).toEqual(['GET'])
    expect(logged()[0].dub).toBe('unchanged')
  })

  it('retries when the commission list can’t be read, and holds GA4’s refund', async () => {
    const response = await handlePolarWebhook(
      delivery('order.refunded', order({ status: 'refunded', refunded_amount: 3900 })),
      env({ dub, fetch: router(() => new Response('{"truncated')) })
    )
    expect(response.status).toBe(502)
    expect(logged()[0]).toMatchObject({ dub: 'failed_status', ga4: 'deferred' })
  })

  it('sets a partially refunded sale to what’s left, which is safe to send again', async () => {
    const partial = order({ status: 'partially_refunded', refunded_amount: 1000 })
    const route = (call: Call) =>
      call.method === 'GET'
        ? Response.json([{ id: 'cm_test_1', status: 'pending' }])
        : Response.json({})
    await handlePolarWebhook(delivery('order.refunded', partial), dubEnv(route))
    expect(calls[1].method).toBe('PATCH')
    expect(calls[1].body).toEqual({ saleAmount: 2900, currency: 'usd' })
    expect(logged()[0].dub).toBe('adjusted')
  })

  it('leaves a refund with no partner alone', async () => {
    const unreferred = order({ status: 'refunded', refunded_amount: 3900, metadata: {} })
    await handlePolarWebhook(delivery('order.refunded', unreferred), dubEnv())
    expect(calls).toEqual([])
    expect(logged()[0].dub).toBe('no_click')
  })

  it('sends to Dub only from the live site', () => {
    expect(dubConfigFromEnv({ SITE_ENV: 'production', DUB_API_KEY: dubApiKey })).toEqual(dub)
    expect(dubConfigFromEnv({ SITE_ENV: 'staging', DUB_API_KEY: dubApiKey })).toBeNull()
    expect(dubConfigFromEnv({ DUB_API_KEY: dubApiKey })).toBeNull()
    expect(dubConfigFromEnv({ SITE_ENV: 'production' })).toBeNull()
  })
})
