// Copies the release index, which names each published release's DMG, into
// src/generated/release-index.json, so /changelog/ can link every release's own download (#565)
// with no network call when the page renders. Like changelog-sources.mjs, it runs before every
// build, typecheck, and dev server, and the output isn't committed.
//
// Where the list comes from (RELEASE_INDEX):
//   live    https://updates.keybumps.app/releases.json, the list publish-release.sh keeps
//           (docs/releases/cloudflare.md). build:staging and build:production read this one.
//   unset   scripts/release-index.fixture.json, a copy of the live list, so `pnpm check`, the
//           tests, and local runs never depend on the network.
//   <path>  that file.
// RELEASE_INDEX_OUTPUT writes somewhere else (the tests use it).
//
// It accepts only a list in the format the release tooling writes (apps/macos/scripts/lib/
// release_index.py): every entry exactly {version, build, url, releasedAt}, each url the immutable
// https://updates.keybumps.app/releases/<build>/Keybumps-<version>.dmg, no version or build twice,
// highest build first. Anything else, or a list it can't read, stops the build with the reason,
// so a deploy fails and the live site keeps its previous version rather than losing the links.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const RELEASE_INDEX_URL = 'https://updates.keybumps.app/releases.json'
const FIELDS = ['build', 'releasedAt', 'url', 'version']
const VERSION = /^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$/
const ATTEMPTS = 3
const TIMEOUT_MS = 15_000
const RETRY_MS = 1000

const web = join(dirname(fileURLToPath(import.meta.url)), '..')

class ReleaseIndexError extends Error {}

/** The checked list, as {version, build, url}, newest first; throws ReleaseIndexError. */
function checkedIndex(value) {
  if (!Array.isArray(value) || value.length === 0)
    throw new ReleaseIndexError('it is not a JSON array of releases')
  const entries = value.map((entry, position) => {
    const where = `entry ${position + 1}`
    if (typeof entry !== 'object' || entry === null || Array.isArray(entry))
      throw new ReleaseIndexError(`${where} is not an object`)
    if (Object.keys(entry).sort().join() !== FIELDS.join())
      throw new ReleaseIndexError(`${where} doesn't have exactly the fields ${FIELDS.join(', ')}`)
    const { version, build, url, releasedAt } = entry
    if (typeof version !== 'string' || !VERSION.test(version))
      throw new ReleaseIndexError(`${where}: ${JSON.stringify(version)} is not a release version`)
    if (!Number.isInteger(build) || build <= 0)
      throw new ReleaseIndexError(
        `${where}: build ${JSON.stringify(build)} is not a positive integer`
      )
    const dmg = `https://updates.keybumps.app/releases/${build}/Keybumps-${version}.dmg`
    if (url !== dmg) throw new ReleaseIndexError(`${where}: url isn't ${dmg}`)
    const time = typeof releasedAt === 'string' ? new Date(releasedAt) : null
    if (
      !time ||
      Number.isNaN(time.getTime()) ||
      time.toISOString() !== releasedAt.replace('Z', '.000Z')
    )
      throw new ReleaseIndexError(`${where}: releasedAt isn't a UTC time like 2026-10-19T12:00:00Z`)
    return { version, build, url }
  })
  for (const field of ['version', 'build']) {
    const values = entries.map(entry => entry[field])
    const twice = values.find((item, position) => values.indexOf(item) !== position)
    if (twice !== undefined) throw new ReleaseIndexError(`${field} ${twice} is listed twice`)
  }
  if (entries.some((entry, position) => position > 0 && entry.build > entries[position - 1].build))
    throw new ReleaseIndexError('its releases are not listed highest build first')
  return entries
}

/** The live list, trying again after a network error or a 5xx. */
async function fetchLive() {
  for (let attempt = 1; ; attempt++) {
    let failure
    try {
      const response = await fetch(RELEASE_INDEX_URL, {
        headers: { accept: 'application/json' },
        signal: AbortSignal.timeout(TIMEOUT_MS)
      })
      if (response.ok) return await response.json()
      failure = `answered HTTP ${response.status}`
      // A 4xx (the zone's bot protection, or no list) won't change on a retry.
      if (response.status < 500) attempt = ATTEMPTS
    } catch (error) {
      failure = `couldn't be read (${error?.name ?? 'error'})`
    }
    if (attempt >= ATTEMPTS) throw new ReleaseIndexError(`${RELEASE_INDEX_URL} ${failure}`)
    await new Promise(done => setTimeout(done, RETRY_MS * attempt))
  }
}

function readFile(path) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'))
  } catch (error) {
    throw new ReleaseIndexError(`${path} couldn't be read as JSON (${error?.name ?? 'error'})`)
  }
}

const source = process.env.RELEASE_INDEX || join(web, 'scripts', 'release-index.fixture.json')
const output =
  process.env.RELEASE_INDEX_OUTPUT || join(web, 'src', 'generated', 'release-index.json')
try {
  const live = source === 'live'
  const entries = checkedIndex(live ? await fetchLive() : readFile(resolve(source)))
  mkdirSync(dirname(output), { recursive: true })
  writeFileSync(output, `${JSON.stringify(entries, null, 2)}\n`)
  const from = live ? RELEASE_INDEX_URL : relative(web, resolve(source))
  console.log(`release-index: ${entries.length} releases from ${from}`)
} catch (error) {
  if (!(error instanceof ReleaseIndexError)) throw error
  console.error(`release-index: the release index is unusable: ${error.message}.`)
  console.error("/changelog/ links each release's DMG from it, so the build stops here.")
  process.exit(1)
}
