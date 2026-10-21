import { readdirSync, readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

// main requires these checks, and a required check must report on every pull request and every
// merge queue group. A workflow skipped by a `paths:` filter never reports, which would block every
// PR that doesn't touch its files. So each workflow runs on all PRs and groups: its `changes` job
// decides whether the slow job runs, and a last gate job, which carries the required check's name,
// passes only if the suite passed or was skipped because the change touches none of its files (SERP
// ci-workflows: "Skip docs-only changes inside the workflow"). Release Keybumps calls the two Mac
// test workflows (`release`), which also decide from a release's tested commit (#615).
const workflows = [
  {
    file: 'keybumps-unit-tests.yml',
    job: 'unit',
    gate: 'unit-tests',
    check: 'Unit tests (KeybumpsTests)',
    // The slow job's name, which Release Keybumps looks up (last-tested.sh).
    run: 'Unit tests (run)',
    release: true
  },
  {
    file: 'keybumps-ui-tests.yml',
    job: 'ui',
    gate: 'ui-tests',
    check: 'UI tests (with retries)',
    run: 'UI tests (run, with retries)',
    release: true
  },
  {
    file: 'web.yml',
    job: 'check',
    gate: 'website-check',
    check: 'Website check (pnpm check)',
    run: undefined,
    release: false
  }
]

const read = (name: string) =>
  readFileSync(
    fileURLToPath(new URL(`../../../../.github/workflows/${name}`, import.meta.url)),
    'utf8'
  )

/** A workflow expression, `${{ … }}`, as the file spells it. */
const expression = (inner: string) => `\${{ ${inner} }}`

/** One job's text, from its `  <id>:` line to the next job's. */
function job(workflow: string, id: string): string {
  const start = workflow.indexOf(`\n  ${id}:\n`)
  expect(start, `job ${id}`).toBeGreaterThanOrEqual(0)
  const next = workflow.slice(start + 1).search(/\n {2}[a-z][\w-]*:\n/)
  return next === -1 ? workflow.slice(start) : workflow.slice(start, start + 1 + next)
}

describe.each(workflows)('$file', ({ file, job: slow, gate, check, run, release }) => {
  const workflow = read(file)
  const trigger = workflow.slice(workflow.indexOf('\non:\n'), workflow.indexOf('\npermissions:'))

  it('runs on every pull request to main, with no paths filter', () => {
    expect(trigger).toContain('pull_request:\n    branches: [main]')
    expect(trigger).not.toMatch(/^\s+paths(-ignore)?:/m)
  })

  // Without the trigger the queue waits on a check that never reports, and no PR merges.
  it('runs in the merge queue', () => {
    expect(trigger).toContain('merge_group:\n    types: [checks_requested]')
  })

  it('decides only on pull requests and merge queue groups (and releases with a tested commit), in a changes job, whether the slow job runs', () => {
    const changes = job(workflow, 'changes')
    const fromRelease = release ? " || inputs.tested_base != ''" : ''
    expect(changes).toContain(
      `if: github.event_name == 'pull_request' || github.event_name == 'merge_group'${fromRelease}\n`
    )
    // In the queue the diff starts at main, not at the group's base_sha (the commit of the entry
    // ahead): otherwise a docs-only PR's group would skip a suite that an app-code PR ahead of it,
    // not yet merged, still needs. An empty value fails the lookup, which runs the suite.
    expect(changes).toMatch(
      /BASE: \$\{\{ github\.event\.pull_request\.base\.sha \|\| github\.event\.merge_group\.base_ref \}\}/
    )
    expect(changes).not.toContain('merge_group.base_sha')
    expect(changes).toContain(
      `HEAD_SHA: \${{ github.event.pull_request.head.sha || github.event.merge_group.head_sha${release ? ' || github.sha' : ''} }}\n`
    )
    // Only Release Keybumps passes a tested commit; an empty one runs the suite. There a failed
    // changes job reads as passed with `run` empty, so the suite runs and the gate needs it to
    // pass; on pull requests and in the queue it still fails the check.
    if (release) {
      expect(changes).toMatch(/^ {4}continue-on-error: \$\{\{ inputs\.tested_base != '' \}\}$/m)
      expect(changes).toContain(`TESTED_BASE: ${expression('inputs.tested_base')}\n`)
      expect(trigger).toContain('  workflow_call:\n    inputs:\n')
      expect(trigger).toMatch(
        / {6}tested_base:\n {8}required: false\n {8}type: string\n {8}default: ""\n/
      )
    } else {
      expect(workflow).not.toContain('tested_base')
      expect(changes).not.toContain('continue-on-error')
    }
    expect(changes).toContain('run: .github/scripts/pr-touches.sh ')
    const suite = job(workflow, slow)
    if (run) expect(suite).toContain(`\n    name: ${run}\n`)
    expect(suite).toMatch(/^ {4}needs: changes$/m)
    expect(suite).toMatch(
      /if: \$\{\{ !cancelled\(\) && needs\.changes\.outputs\.run != 'false' \}\}/
    )
    expect(suite).not.toContain(`name: ${check}\n`)
  })

  it('reports the required check from a gate that always runs and passes only on purpose', () => {
    const gateJob = job(workflow, gate)
    expect(gateJob).toContain(`name: ${check}\n`)
    expect(gateJob).toContain(`needs: [changes, ${slow}]`)
    expect(gateJob).toMatch(/if: \$\{\{ always\(\) \}\}/)
    // The gate reads these; a wrong one could pass a failing suite.
    expect(gateJob).toMatch(/CHANGES: \$\{\{ needs\.changes\.result \}\}/)
    expect(gateJob).toMatch(/RUN: \$\{\{ needs\.changes\.outputs\.run \}\}/)
    expect(gateJob).toMatch(new RegExp(`SUITE: \\$\\{\\{ needs\\.${slow}\\.result \\}\\}`))
    expect(gateJob).toContain('if [ "$SUITE" = success ]; then exit 0; fi')
    expect(gateJob).toContain(
      'if [ "$SUITE" = skipped ] && [ "$CHANGES" = success ] && [ "$RUN" = false ]; then'
    )
    expect(gateJob).toContain('exit 1')
  })

  // Every build bundles the release notes: the unit suite parses them and the UI suite opens
  // Settings › Changelog, and the site builds /changelog/ from them.
  it('covers its own workflow file, the script, and the release notes in its pattern', () => {
    const pattern = new RegExp(workflow.match(/pr-touches\.sh '([^']+)'/)?.[1] ?? '$^')
    expect(pattern.test(`.github/workflows/${file}`)).toBe(true)
    expect(pattern.test('.github/scripts/pr-touches.sh')).toBe(true)
    expect(
      pattern.test(
        file === 'web.yml' ? 'apps/web/src/app/site.css' : 'apps/macos/Keybumps/App/AppModel.swift'
      )
    ).toBe(true)
    expect(pattern.test('docs/releases/v0.0.3-beta.24.md')).toBe(true)
    expect(pattern.test('docs/releases/sparkle-update-operations.md')).toBe(false)
    expect(pattern.test('AGENTS.md')).toBe(false)
  })
})

it("runs the website check on every workflow file, since the site's tests read them all", () => {
  const pattern = new RegExp(read('web.yml').match(/pr-touches\.sh '([^']+)'/)?.[1] ?? '$^')
  const dir = fileURLToPath(new URL('../../../../.github/workflows/', import.meta.url))
  const files = readdirSync(dir).filter(file => file.endsWith('.yml'))
  expect(files.length).toBeGreaterThan(0)
  for (const file of files) {
    expect(pattern.test(`.github/workflows/${file}`), file).toBe(true)
  }
})

it('runs the website check on every script in .github/scripts, since the site runs their tests', () => {
  const pattern = new RegExp(read('web.yml').match(/pr-touches\.sh '([^']+)'/)?.[1] ?? '$^')
  const dir = fileURLToPath(new URL('../../../../.github/scripts/', import.meta.url))
  const files = readdirSync(dir).filter(file => file.endsWith('.sh'))
  expect(files).toContain('last-tested.sh')
  for (const file of files) {
    expect(pattern.test(`.github/scripts/${file}`), file).toBe(true)
  }
})

// Release Keybumps also skips a suite on a commit with a passing check run of its slow job's name.
it('gives no other job a required check name, or a suite name the release looks up, which could report it without running the suite', () => {
  const guarded = workflows.flatMap(({ check, run }) => (run ? [check, run] : [check]))
  const dir = fileURLToPath(new URL('../../../../.github/workflows/', import.meta.url))
  for (const file of readdirSync(dir).filter(name => name.endsWith('.yml'))) {
    const names = [...read(file).matchAll(/^ {4}name: (.+)$/gm)].map(match => match[1].trim())
    const own = workflows.find(workflow => workflow.file === file)
    const allowed = own ? [own.check, own.run] : []
    for (const name of names.filter(name => guarded.includes(name))) {
      expect(allowed, `${file} has a job named "${name}"`).toContain(name)
    }
  }
})

// Release Keybumps runs the unit and UI suites before it builds, but each only if the files it covers
// changed since a commit where it passed, normally in the merge queue (owner, 2026-10-21, #615). The
// lookup (.github/scripts/last-tested.sh, tested in last-tested.test.ts) must never stop a release,
// and only the test workflows' own gates decide a skip.
describe('release.yml', () => {
  const release = read('release.yml')
  const tested = job(release, 'tested')
  const steps = tested.split('      - name: ').slice(1)
  const suites = [
    { id: 'unit-tests', file: 'keybumps-unit-tests.yml', output: 'unit', slow: 'unit' },
    { id: 'ui-tests', file: 'keybumps-ui-tests.yml', output: 'ui', slow: 'ui' }
  ]

  // A branch's commits can carry pull request runs, which tested the branch merged into main.
  it('looks up tested commits only from main, with read permissions only, and never fails', () => {
    expect(tested).toContain("if: github.ref == 'refs/heads/main'\n")
    expect(tested).toMatch(/^ {4}continue-on-error: true$/m)
    expect(tested).toMatch(/^ {4}permissions:\n {6}contents: read\n {6}checks: read\n {4}outputs:/m)
    expect(steps).toHaveLength(3)
    for (const step of steps) expect(step).toMatch(/^ {8}continue-on-error: true$/m)
    expect(steps[0]).toMatch(
      /persist-credentials: false\n {10}sparse-checkout: \.github\/scripts\n/
    )
  })

  it.each(suites)(
    "passes $file the commit where its suite's exact job name last passed",
    ({ id, file, output, slow }) => {
      const name = job(read(file), slow).match(/^ {4}name: (.+)$/m)?.[1]
      expect(name).toBeDefined()
      const step = steps.find(text => text.includes(`id: ${output}\n`))
      expect(step).toContain(`HEAD_SHA: ${expression('github.sha')}\n`)
      expect(step).toContain(`run: .github/scripts/last-tested.sh '${name}'\n`)
      expect(tested).toContain(`${output}: \${{ steps.${output}.outputs.sha }}\n`)
      const caller = job(release, id)
      expect(caller).toContain(`uses: ./.github/workflows/${file}\n`)
      expect(caller).toContain(`tested_base: \${{ needs.tested.outputs.${output} }}\n`)
    }
  )

  it.each(suites)('runs $file even if the lookup failed or was skipped', ({ id }) => {
    const caller = job(release, id)
    expect(caller).toMatch(/^ {4}needs: tested$/m)
    expect(caller).toContain(`if: ${expression('!cancelled()')}\n`)
  })

  // A job's default condition also needs every job before its needs to have succeeded, so without
  // these a failed or skipped lookup would skip the build and production.
  it('builds and publishes only after both suites pass or skip on purpose, whatever the lookup did', () => {
    const build = job(release, 'build')
    expect(build).toMatch(/^ {4}needs: \[unit-tests, ui-tests\]$/m)
    expect(build).toContain(
      `if: ${expression("!cancelled() && needs.unit-tests.result == 'success' && needs.ui-tests.result == 'success'")}\n`
    )
    const production = job(release, 'production')
    expect(production).toMatch(/^ {4}needs: build$/m)
    expect(production).toContain(
      `if: ${expression("!cancelled() && inputs.publish && needs.build.result == 'success'")}\n`
    )
  })

  // A called workflow can't have more permissions than its caller grants.
  it('gets the check runs permission from release-please, and nothing broader', () => {
    const caller = job(read('release-please.yml'), 'release')
    expect(caller).toMatch(/^ {4}permissions:\n {6}contents: read\n {6}checks: read\n {4}uses: /m)
  })
})
