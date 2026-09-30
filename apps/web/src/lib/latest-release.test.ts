import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  FALLBACK_RELEASE,
  getLatestRelease,
  parseLatestRelease,
} from './latest-release.ts';

const valid = {
  version: '0.0.3-beta.4',
  build: 4008,
  dmgURL:
    'https://updates.keybumps.app/releases/4008/Keybumps-0.0.3-beta.4.dmg',
  sha256: 'ab'.repeat(32),
};

const respond = (body: unknown, status = 200) =>
  (async () =>
    new Response(JSON.stringify(body), { status })) as unknown as typeof fetch;

test('accepts the pointer written by the release tooling', () => {
  assert.deepEqual(parseLatestRelease(valid), valid);
});

test('rejects foreign, insecure, or mismatched download links', () => {
  for (const dmgURL of [
    'https://evil.example/releases/4008/Keybumps-0.0.3-beta.4.dmg',
    'http://updates.keybumps.app/releases/4008/Keybumps-0.0.3-beta.4.dmg',
    'https://updates.keybumps.app/releases/4008/Keybumps-0.0.3-beta.4.dmg?x=1',
    'https://user@updates.keybumps.app/releases/4008/Keybumps-0.0.3-beta.4.dmg',
    'https://updates.keybumps.app/releases/4008/Keybumps-9.9.9.dmg',
    'not a url',
  ]) {
    assert.equal(parseLatestRelease({ ...valid, dmgURL }), null, dmgURL);
  }
});

test('rejects malformed fields', () => {
  assert.equal(parseLatestRelease(null), null);
  assert.equal(parseLatestRelease({ ...valid, build: '4008' }), null);
  assert.equal(parseLatestRelease({ ...valid, build: 0 }), null);
  assert.equal(parseLatestRelease({ ...valid, sha256: 'xyz' }), null);
  assert.equal(parseLatestRelease({ ...valid, version: 'latest' }), null);
});

test('serves the published release and falls back on any failure', async () => {
  assert.deepEqual(await getLatestRelease(respond(valid)), valid);
  assert.deepEqual(await getLatestRelease(respond({}, 404)), FALLBACK_RELEASE);
  assert.deepEqual(
    await getLatestRelease(
      respond({ ...valid, dmgURL: 'https://evil.example/x.dmg' }),
    ),
    FALLBACK_RELEASE,
  );
  const offline = (async () => {
    throw new Error('offline');
  }) as unknown as typeof fetch;
  assert.deepEqual(await getLatestRelease(offline), FALLBACK_RELEASE);
});

test('the fallback itself is a valid pointer', () => {
  assert.deepEqual(parseLatestRelease(FALLBACK_RELEASE), FALLBACK_RELEASE);
});
