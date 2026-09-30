import { expect, test } from 'vitest'
import { FALLBACK_RELEASE, getLatestRelease, parseLatestRelease } from './latest-release'

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

test('the fallback itself is a valid pointer', () => {
  expect(parseLatestRelease(FALLBACK_RELEASE)).toEqual(FALLBACK_RELEASE)
})
