import { spawnSync } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { afterAll, describe, expect, it } from 'vitest'

// scripts/release-index.mjs copies the release index into the build, for /changelog/'s download
// links, and stops the build when the list can't be read or isn't in the release tooling's format.
// It runs here on files, and its live read against a stub fetch loaded with --import: never the
// network.
const web = fileURLToPath(new URL('../..', import.meta.url))
const script = join(web, 'scripts', 'release-index.mjs')
const fixture = JSON.parse(readFileSync(join(web, 'scripts', 'release-index.fixture.json'), 'utf8'))
const scratch = mkdtempSync(join(tmpdir(), 'release-index-'))
afterAll(() => rmSync(scratch, { recursive: true, force: true }))

// Answers each fetch with the next of FAKE_ANSWERS (a status, or "error" for a network failure),
// runs retry waits at once, and records how many fetches there were.
const stub = join(scratch, 'stub-fetch.mjs')
writeFileSync(
  stub,
  `import { writeFileSync } from 'node:fs'
const answers = JSON.parse(process.env.FAKE_ANSWERS)
let calls = 0
process.on('exit', () => writeFileSync(process.env.FAKE_CALLS, String(calls)))
globalThis.setTimeout = done => queueMicrotask(done)
globalThis.fetch = async url => {
  if (String(url) !== 'https://updates.keybumps.app/releases.json') throw new Error('unexpected URL')
  const answer = answers[calls++]
  if (answer === 'error') throw new TypeError('fetch failed')
  return new Response(answer === 200 ? process.env.FAKE_BODY : 'no', { status: answer })
}
`
)

type Run = { status: number | null; stderr: string; written: unknown; calls?: number }

function run(source: string, env: Record<string, string> = {}, preload = false): Run {
  const id = Math.random().toString(36).slice(2)
  const output = join(scratch, `output-${id}.json`)
  const calls = join(scratch, `calls-${id}`)
  const result = spawnSync(process.execPath, [...(preload ? ['--import', stub] : []), script], {
    env: {
      ...process.env,
      RELEASE_INDEX: source,
      RELEASE_INDEX_OUTPUT: output,
      FAKE_CALLS: calls,
      ...env
    },
    encoding: 'utf8'
  })
  return {
    status: result.status,
    stderr: result.stderr,
    written: existsSync(output) ? JSON.parse(readFileSync(output, 'utf8')) : null,
    ...(preload ? { calls: Number(readFileSync(calls, 'utf8')) } : {})
  }
}

/** Runs the script on a file holding `list`. */
function runOn(list: unknown): Run {
  const file = join(scratch, `list-${Math.random().toString(36).slice(2)}.json`)
  writeFileSync(file, JSON.stringify(list))
  return run(file)
}

/** Runs the script's live read against the stub. */
function runLive(answers: (number | 'error')[], body: unknown = fixture): Run {
  return run(
    'live',
    { FAKE_ANSWERS: JSON.stringify(answers), FAKE_BODY: JSON.stringify(body) },
    true
  )
}

const copied = (list: { version: string; build: number; url: string }[]) =>
  list.map(({ version, build, url }) => ({ version, build, url }))

const entry = (version: string, build: number, releasedAt = '2026-10-19T19:24:10Z') => ({
  version,
  build,
  url: `https://updates.keybumps.app/releases/${build}/Keybumps-${version}.dmg`,
  releasedAt
})

describe('scripts/release-index.mjs', () => {
  it('copies the fixture, a copy of the live list, when no source is set', () => {
    const result = run('')
    expect(result.status).toBe(0)
    expect(result.written).toEqual(copied(fixture))
    expect(fixture.length).toBeGreaterThan(20)
  })

  it('accepts a list in the release tooling format, keeping only what the page needs', () => {
    const list = [entry('0.0.3-beta.29', 4034), entry('0.0.3-beta.6', 4011)]
    expect(runOn(list)).toMatchObject({ status: 0, written: copied(list) })
  })

  it('stops the build, writing nothing, on a list in any other shape', () => {
    const good = entry('0.0.3-beta.29', 4034)
    const { releasedAt: _, ...noDate } = good
    // Each problem, a list with it, and the reason the build prints.
    const lists: [string, unknown, string][] = [
      ['not a list', { releases: [good] }, 'not a JSON array'],
      ['an empty list', [], 'not a JSON array'],
      ['an entry that is not an object', ['0.0.3-beta.29'], 'entry 1 is not an object'],
      ['an extra field', [{ ...good, sha256: 'ab'.repeat(32) }], 'exactly the fields'],
      ['a missing field', [noDate], 'exactly the fields'],
      ['a version that is not one', [{ ...good, version: 'beta.29' }], 'not a release version'],
      ['a build that is a string', [{ ...good, build: '4034' }], 'not a positive integer'],
      ['a fractional build', [{ ...good, build: 4034.5 }], 'not a positive integer'],
      ['a build of zero', [entry('0.0.3-beta.29', 0)], 'not a positive integer'],
      ['an insecure url', [{ ...good, url: good.url.replace('https:', 'http:') }], "url isn't"],
      ['another host', [{ ...good, url: good.url.replace('updates.', 'evil.') }], "url isn't"],
      ['a url with a query', [{ ...good, url: `${good.url}?x=1` }], "url isn't"],
      [
        'another build in the url',
        [{ ...good, url: good.url.replace('4034', '4033') }],
        "url isn't"
      ],
      [
        'another version in its url',
        [{ ...good, url: good.url.replace('.29', '.28') }],
        "url isn't"
      ],
      ['a date with no time', [{ ...good, releasedAt: '2026-10-19' }], 'releasedAt'],
      [
        'a day that does not exist',
        [{ ...good, releasedAt: '2026-02-30T12:00:00Z' }],
        'releasedAt'
      ],
      ['a version twice', [entry('0.0.3-beta.6', 4011), entry('0.0.3-beta.6', 4010)], 'version'],
      ['a build twice', [entry('0.0.3-beta.6', 4011), entry('0.0.3-beta.5', 4011)], 'build 4011'],
      ['oldest first', [entry('0.0.3-beta.28', 4033), entry('0.0.3-beta.29', 4034)], 'highest']
    ]
    for (const [problem, list, reason] of lists) {
      const result = runOn(list)
      expect(result.status, problem).toBe(1)
      expect(result.stderr, problem).toMatch(/release index is unusable: .+\n.*build stops/)
      expect(result.stderr.split('\n')[0], problem).toContain(reason)
      expect(result.written, problem).toBeNull()
    }
  })

  it('stops the build on a file it cannot read as JSON', () => {
    const file = join(scratch, 'broken.json')
    writeFileSync(file, '[{')
    for (const source of [file, join(scratch, 'missing.json')]) {
      const result = run(source)
      expect(result.status, source).toBe(1)
      expect(result.stderr, source).toContain("couldn't be read as JSON")
      expect(result.written, source).toBeNull()
    }
  })

  it('reads the live list from updates.keybumps.app', () => {
    expect(runLive([200])).toMatchObject({ status: 0, written: copied(fixture), calls: 1 })
  })

  it('stops the build at once when the release origin refuses, as bot protection does', () => {
    const result = runLive([403, 200])
    expect(result).toMatchObject({ status: 1, written: null, calls: 1 })
    expect(result.stderr).toContain('https://updates.keybumps.app/releases.json answered HTTP 403')
  })

  it('tries again after a server error or a network failure, then stops the build', () => {
    expect(runLive([503, 'error', 200])).toMatchObject({ status: 0, calls: 3 })
    const result = runLive(['error', 503, 'error', 200])
    expect(result).toMatchObject({ status: 1, written: null, calls: 3 })
    expect(result.stderr).toContain("releases.json couldn't be read (TypeError)")
  })

  it('stops the build when the live list is not in the release tooling format', () => {
    const result = runLive(
      [200],
      [{ ...entry('0.0.3-beta.29', 4034), url: 'https://evil.example/' }]
    )
    expect(result).toMatchObject({ status: 1, written: null })
    expect(result.stderr).toContain('entry 1: url')
  })

  it('reads the real list in the deployed builds only', () => {
    const { scripts } = JSON.parse(readFileSync(join(web, 'package.json'), 'utf8'))
    expect(scripts['changelog:sources']).toContain('node scripts/release-index.mjs')
    for (const name of ['build', 'dev', 'typecheck'])
      expect(scripts[name], name).toContain('pnpm changelog:sources')
    // The deployed builds take the workflow's copy, or the live list when none is passed: never
    // the fixture.
    for (const [name, command] of Object.entries<string>(scripts))
      expect(command.includes('RELEASE_INDEX=${RELEASE_INDEX:-live} '), name).toBe(
        name === 'build:staging' || name === 'build:production'
      )
  })

  it('has web-deploy.yml read the list from R2, with the token in that step only', () => {
    const deploy = readFileSync(
      join(web, '..', '..', '.github', 'workflows', 'web-deploy.yml'),
      'utf8'
    )
    const steps = deploy.split(/\n(?=\s+- name: )/)
    const named = (name: string) => steps.filter(step => step.includes(`- name: ${name}\n`))
    const reads = named('Read the release index from R2')
    expect(reads).toHaveLength(2)
    for (const step of reads) {
      expect(step).toContain('working-directory: ${{ runner.temp }}')
      expect(step).toContain(
        'r2 object get keybumps-updates/releases.json --remote --file "$RUNNER_TEMP/releases.json"'
      )
      expect(step).not.toMatch(/pnpm|node |scripts\//)
    }
    // Only those steps get the token, each before the job installs or builds anything.
    expect(steps.filter(step => step.includes('secrets.CLOUDFLARE_R2_TOKEN'))).toEqual(reads)
    expect(deploy).not.toMatch(/^env:/m)
    for (const job of deploy
      .split(/\n(?=  [a-z]+:\n)/)
      .filter(job => job.includes('pnpm build:'))) {
      const read = job.indexOf('- name: Read the release index from R2')
      expect(read).toBeGreaterThan(0)
      expect(read).toBeLessThan(job.indexOf('- name: Install dependencies'))
    }
    for (const build of ['build:staging', 'build:production']) {
      const step = named('Build').find(step => step.includes(`run: pnpm ${build}`))
      expect(step, build).toContain('RELEASE_INDEX: ${{ runner.temp }}/releases.json')
    }
  })
})
