import { spawnSync } from 'node:child_process'
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { afterAll, describe, expect, it } from 'vitest'

// .github/scripts/last-tested.sh finds the newest commit in a release's history where a suite
// passed, and the release skips the suite when none of its files changed since (#615).
// When unsure it must write an empty sha, which runs the suite: a wrong commit could skip a suite
// the release's code never passed.
// It runs here with a stub `gh` that prints canned results, as `--jq` would, never the real API. The
// stub ignores the API's name filter, so these tests show the script's own exact-name check.
const script = fileURLToPath(new URL('../../../../.github/scripts/last-tested.sh', import.meta.url))
const scratch = mkdtempSync(join(tmpdir(), 'last-tested-'))
writeFileSync(
  join(scratch, 'gh'),
  [
    '#!/usr/bin/env bash',
    'printf "%s\\n" "$*" >>"$FAKE_GH_LOG"',
    'case "$4" in',
    `  */check-runs) sha="\${4%/check-runs}"; file="$FAKE_GH_DIR/runs-\${sha##*/}" ;;`,
    '  *) file="$FAKE_GH_DIR/commits" ;;',
    'esac',
    '[ -e "$file.fail" ] && exit 1',
    'cat "$file" 2>/dev/null',
    'exit 0',
    ''
  ].join('\n')
)
chmodSync(join(scratch, 'gh'), 0o755)
afterAll(() => rmSync(scratch, { recursive: true, force: true }))

const unit = 'Unit tests (run)'
const ui = 'UI tests (run, with retries)'

type CheckRun = [name: string, conclusion: string]

interface History {
  /** The release's commits, newest first; the first is HEAD_SHA. */
  commits: string[]
  /** Each commit's check runs. */
  runs?: Record<string, CheckRun[]>
  /** The calls that fail: 'commits' for the list, or a commit whose check runs can't be read. */
  fail?: string[]
}

/** The `gh` calls the last run made, one line of arguments each. */
let calls: string[] = []

/** Runs the script for a check name against a history, and returns the sha it wrote. */
function lastTested({ commits, runs = {}, fail = [] }: History, name = unit): string | undefined {
  const dir = mkdtempSync(join(scratch, 'run-'))
  writeFileSync(join(dir, 'commits'), commits.join('\n'))
  for (const [sha, list] of Object.entries(runs)) {
    writeFileSync(join(dir, `runs-${sha}`), list.map(run => run.join('\t')).join('\n'))
  }
  for (const what of fail) {
    writeFileSync(join(dir, what === 'commits' ? 'commits.fail' : `runs-${what}.fail`), '')
  }
  const output = join(dir, 'output')
  const log = join(dir, 'log')
  writeFileSync(output, '')
  writeFileSync(log, '')
  spawnSync('bash', [script, name], {
    env: {
      ...process.env,
      PATH: `${scratch}:${process.env.PATH}`,
      FAKE_GH_DIR: dir,
      FAKE_GH_LOG: log,
      GITHUB_REPOSITORY: 'example/repo',
      HEAD_SHA: commits[0] ?? 'head',
      GITHUB_OUTPUT: output
    }
  })
  calls = readFileSync(log, 'utf8').split('\n').filter(Boolean)
  return readFileSync(output, 'utf8').match(/^sha=(\w*)$/m)?.[1]
}

const commits = ['c3', 'c2', 'c1']

describe('.github/scripts/last-tested.sh', () => {
  it('finds the newest commit where the suite passed, and stops there', () => {
    const runs: History['runs'] = {
      c3: [[unit, 'skipped']],
      c2: [[unit, 'success']],
      c1: [[unit, 'success']]
    }
    expect(lastTested({ commits, runs })).toBe('c2')
    expect(calls).toHaveLength(3)
  })

  it('finds the release commit itself when the suite passed there', () => {
    expect(lastTested({ commits, runs: { c3: [[unit, 'success']] } })).toBe('c3')
  })

  it("matches the name exactly, so the release's own runs and other suites don't count", () => {
    const runs: History['runs'] = {
      c3: [
        [`release / unit-tests / ${unit}`, 'success'],
        [`unit-tests / ${unit}`, 'success'],
        [unit, 'skipped']
      ],
      c2: [[ui, 'success']],
      c1: [[unit, 'success']]
    }
    expect(lastTested({ commits, runs })).toBe('c1')
    expect(lastTested({ commits, runs }, ui)).toBe('c2')
  })

  it('passes over a commit whose suite failed, was cancelled, or is still running', () => {
    const runs: History['runs'] = {
      c3: [[unit, 'failure']],
      c2: [
        [unit, 'cancelled'],
        [unit, '']
      ],
      c1: [[unit, 'success']]
    }
    expect(lastTested({ commits, runs })).toBe('c1')
  })

  // An admin bypass of the merge queue leaves a commit on main with no check runs of the suites.
  it('passes over a commit with no check runs', () => {
    expect(lastTested({ commits, runs: { c1: [[unit, 'success']] } })).toBe('c1')
  })

  it.each<[string, History]>([
    ['no listed commit passed', { commits, runs: { c3: [[unit, 'skipped']] } }],
    [
      "the commits can't be listed",
      { commits, runs: { c1: [[unit, 'success']] }, fail: ['commits'] }
    ],
    [
      "a commit's check runs can't be read, even if an older one passed",
      { commits, runs: { c2: [[unit, 'success']] }, fail: ['c3'] }
    ]
  ])('writes an empty sha, which runs the suite, when %s', (_, history) => {
    expect(lastTested(history)).toBe('')
  })

  it("lists HEAD_SHA's newest 50 commits, and asks for the check runs of the exact name", () => {
    lastTested({ commits, runs: { c2: [[ui, 'success']] } }, ui)
    expect(calls[0]).toBe(
      'api --method GET repos/example/repo/commits -f sha=c3 -f per_page=50 --jq .[].sha'
    )
    expect(calls[1]).toMatch(
      /^api --method GET repos\/example\/repo\/commits\/c3\/check-runs -f check_name=UI tests \(run, with retries\) -f per_page=100 /
    )
    expect(calls).toHaveLength(3)
  })
})
