// Copies the release index, which names each published release's DMG, into
// src/generated/release-index.json, so /changelog/ can link every release's own download (#565)
// with no network call when the page renders. Like changelog-sources.mjs, it runs before every
// build, typecheck, and dev server, and the output isn't committed.
//
// Where the list comes from (RELEASE_INDEX):
//   <path>  that file. web-deploy.yml reads releases.json, the list publish-release.sh keeps
//           (docs/releases/cloudflare.md), from R2 and passes its copy to build:staging and
//           build:production, because GitHub-hosted runners get HTTP 403 from updates.keybumps.app.
//   live    https://updates.keybumps.app/releases.json, what build:staging and build:production
//           read when RELEASE_INDEX isn't set (from a normal network; on a runner it stops).
//   unset   scripts/release-index.fixture.json, a copy of the live list, so `pnpm check`, the
//           tests, and local runs never depend on the network.
// RELEASE_INDEX_OUTPUT writes somewhere else (the tests use it).
//
// It accepts only a list in the format the release tooling writes (apps/macos/scripts/lib/
// release_index.py): every entry exactly {version, build, url, releasedAt}, each url the immutable
// https://updates.keybumps.app/releases/<build>/Keybumps-<version>.dmg, no version or build twice,
// highest build first. Anything else, or a list it can't read, stops the build with the reason,
// so a deploy fails and the live site keeps its previous version rather than losing the links.
//
// A list read for a deployed build (RELEASE_INDEX set: the live list or a file) must also hold
// every version the fixture lists, each with the same build. The release tooling only adds or
// replaces entries (docs/releases/cloudflare.md), so a shorter list is a bad copy, such as a
// restore from an old one, and would silently drop links. Newer versions are fine. Removing a
// version on purpose means removing it from the fixture too.
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
const fixture = join(web, 'scripts', 'release-index.fixture.json')

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

/** Throws ReleaseIndexError unless `entries` lists every fixture version with the same build. */
function checkCoverage(entries) {
  const builds = new Map(entries.map(entry => [entry.version, entry.build]))
  const known = checkedIndex(readFile(fixture))
  const missing = known.filter(entry => !builds.has(entry.version)).map(entry => entry.version)
  const moved = known
    .filter(entry => builds.has(entry.version) && builds.get(entry.version) !== entry.build)
    .map(entry => `${entry.version} (build ${builds.get(entry.version)}, not ${entry.build})`)
  const problems = [
    missing.length && `it lacks ${missing.join(', ')}`,
    moved.length && `it lists ${moved.join(', ')}`
  ].filter(Boolean)
  if (problems.length)
    throw new ReleaseIndexError(
      `${problems.join('; ')}, which scripts/release-index.fixture.json lists. A deployed build ` +
        'needs every release the fixture names, with the same build'
    )
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

const source = process.env.RELEASE_INDEX || fixture
const output =
  process.env.RELEASE_INDEX_OUTPUT || join(web, 'src', 'generated', 'release-index.json')
try {
  const live = source === 'live'
  const entries = checkedIndex(live ? await fetchLive() : readFile(resolve(source)))
  if (process.env.RELEASE_INDEX) checkCoverage(entries)
  mkdirSync(dirname(output), { recursive: true })
  writeFileSync(output, `${JSON.stringify(entries, null, 2)}\n`)
  const path = relative(web, resolve(source))
  const from = live ? RELEASE_INDEX_URL : path.startsWith('..') ? resolve(source) : path
  console.log(`release-index: ${entries.length} releases from ${from}`)
} catch (error) {
  if (!(error instanceof ReleaseIndexError)) throw error
  console.error(`release-index: the release index is unusable: ${error.message}.`)
  console.error("/changelog/ links each release's DMG from it, so the build stops here.")
  process.exit(1)
}
