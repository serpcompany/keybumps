import { afterEach, describe, expect, it, test, vi } from 'vitest'
import * as downloadRoute from '@/app/download/route'
import {
  DOWNLOAD_REDIRECT_STATUS,
  downloadRedirect,
  FALLBACK_RELEASE,
  getLatestRelease,
  LATEST_RELEASE_TIMEOUT_MS,
  parseLatestRelease
} from './latest-release'

const valid = {
  version: '0.0.3-beta.4',
  build: 4008,
  dmgURL: 'https://updates.keybumps.app/releases/4008/Keybumps-0.0.3-beta.4.dmg',
  sha256: 'ab'.repeat(32)
}

const respond = (body: unknown, status = 200) =>
  (async () => new Response(JSON.stringify(body), { status })) as unknown as typeof fetch

test('accepts the pointer written by the release tooling', () => {
  expect(parseLatestRelease(valid)).toEqual(valid)
})

test('rejects foreign, insecure, or mismatched download links', () => {
  for (const dmgURL of [
    'https://evil.example/releases/4008/Keybumps-0.0.3-beta.4.dmg',
    'http://updates.keybumps.app/releases/4008/Keybumps-0.0.3-beta.4.dmg',
    'https://updates.keybumps.app/releases/4008/Keybumps-0.0.3-beta.4.dmg?x=1',
    'https://user@updates.keybumps.app/releases/4008/Keybumps-0.0.3-beta.4.dmg',
    'https://updates.keybumps.app/releases/4008/Keybumps-9.9.9.dmg',
    'not a url'
  ]) {
    expect(parseLatestRelease({ ...valid, dmgURL }), dmgURL).toBeNull()
  }
})

test('rejects malformed fields', () => {
  expect(parseLatestRelease(null)).toBeNull()
  expect(parseLatestRelease({ ...valid, build: '4008' })).toBeNull()
  expect(parseLatestRelease({ ...valid, build: 0 })).toBeNull()
  expect(parseLatestRelease({ ...valid, sha256: 'xyz' })).toBeNull()
  expect(parseLatestRelease({ ...valid, version: 'latest' })).toBeNull()
})

test('serves the published release and falls back on any failure', async () => {
  expect(await getLatestRelease(respond(valid))).toEqual(valid)
  expect(await getLatestRelease(respond({}, 404))).toEqual(FALLBACK_RELEASE)
  expect(
    await getLatestRelease(respond({ ...valid, dmgURL: 'https://evil.example/x.dmg' }))
  ).toEqual(FALLBACK_RELEASE)
  const offline = (async () => {
    throw new Error('offline')
  }) as unknown as typeof fetch
  expect(await getLatestRelease(offline)).toEqual(FALLBACK_RELEASE)
})

test('falls back when latest.json is too slow, instead of stalling the page', async () => {
  // Like fetch, this never answers on its own and rejects when its signal aborts.
  const hanging = ((_url: string, init?: RequestInit) =>
    new Promise((_resolve, reject) => {
      init?.signal?.addEventListener('abort', () => reject(init.signal?.reason))
    })) as unknown as typeof fetch
  const started = Date.now()
  expect(await getLatestRelease(hanging, 50)).toEqual(FALLBACK_RELEASE)
  expect(Date.now() - started).toBeLessThan(1000)
})

test('bounds every lookup with a timeout signal by default', async () => {
  let signal: AbortSignal | null | undefined
  const spy = (async (_url: string, init?: RequestInit) => {
    signal = init?.signal
    return new Response(JSON.stringify(valid))
  }) as unknown as typeof fetch
  expect(await getLatestRelease(spy)).toEqual(valid)
  expect(signal).toBeInstanceOf(AbortSignal)
  expect(LATEST_RELEASE_TIMEOUT_MS).toBeLessThanOrEqual(2000)
})

test('the fallback itself is a valid pointer', () => {
  expect(parseLatestRelease(FALLBACK_RELEASE)).toEqual(FALLBACK_RELEASE)
})

test('/download/ redirects to the DMG temporarily, and nothing caches it', () => {
  const response = downloadRedirect(valid)
  // Never 301 or 308: browsers keep permanent redirects, and the DMG changes with each release.
  expect([302, 307]).toContain(response.status)
  expect(response.status).toBe(DOWNLOAD_REDIRECT_STATUS)
  expect(response.headers.get('location')).toBe(valid.dmgURL)
  expect(response.headers.get('cache-control')).toBe('no-store')
})

describe('the /download/ route', () => {
  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('runs on every request, so it never keeps the build-time DMG', () => {
    expect(downloadRoute.dynamic).toBe('force-dynamic')
  })

  it('sends the DMG named by latest.json', async () => {
    vi.stubGlobal('fetch', respond(valid))
    const response = await downloadRoute.GET()
    expect(response.status).toBe(DOWNLOAD_REDIRECT_STATUS)
    expect(response.headers.get('location')).toBe(valid.dmgURL)
  })

  it('sends the fallback DMG when latest.json is unavailable', async () => {
    vi.stubGlobal('fetch', respond({}, 503))
    const response = await downloadRoute.GET()
    expect(response.headers.get('location')).toBe(FALLBACK_RELEASE.dmgURL)
  })
})
