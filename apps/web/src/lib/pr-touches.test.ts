import { spawnSync } from 'node:child_process'
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { afterAll, describe, expect, it } from 'vitest'

// .github/scripts/pr-touches.sh decides whether a required check's slow job runs on a pull request
// or a merge queue group.
// When unsure it must say run=true: a wrong run=false skips a required suite and passes the check.
// It runs here with a stub `gh` that prints a canned compare result, never the real API.
const script = fileURLToPath(new URL('../../../../.github/scripts/pr-touches.sh', import.meta.url))
const scratch = mkdtempSync(join(tmpdir(), 'pr-touches-'))
writeFileSync(
  join(scratch, 'gh'),
  '#!/usr/bin/env bash\nprintf "%s" "$FAKE_GH_OUTPUT"\nexit "$FAKE_GH_EXIT"\n'
)
chmodSync(join(scratch, 'gh'), 0o755)
afterAll(() => rmSync(scratch, { recursive: true, force: true }))

const appCode = '^(apps/macos/|\\.github/workflows/keybumps-unit-tests\\.yml$)'

/** Runs the script for a pull request (or another event) against a compare result's lines. */
function run(lines: string[], { event = 'pull_request', ghExit = 0 } = {}): string | undefined {
  const output = join(scratch, `output-${Math.random()}`)
  writeFileSync(output, '')
  spawnSync('bash', [script, appCode], {
    env: {
      ...process.env,
      PATH: `${scratch}:${process.env.PATH}`,
      FAKE_GH_OUTPUT: lines.join('\n'),
      FAKE_GH_EXIT: String(ghExit),
      GITHUB_EVENT_NAME: event,
      GITHUB_REPOSITORY: 'example/repo',
      BASE: 'base123',
      HEAD_SHA: 'head456',
      GITHUB_OUTPUT: output
    }
  })
  return readFileSync(output, 'utf8').match(/^run=(\w+)$/m)?.[1]
}

const changed = (files: string[]) => [String(files.length), ...files]

describe('.github/scripts/pr-touches.sh', () => {
  it('runs the check when the PR touches its files', () => {
    expect(run(changed(['README.md', 'apps/macos/Keybumps/App/AppModel.swift']))).toBe('true')
  })

  it('skips it when the PR touches none of them', () => {
    expect(run(changed(['AGENTS.md', 'apps/web/src/app/site.css']))).toBe('false')
  })

  it('decides the same way for a merge queue group', () => {
    const event = 'merge_group'
    expect(run(changed(['AGENTS.md', 'apps/web/src/app/site.css']), { event })).toBe('false')
    expect(run(changed(['AGENTS.md', 'apps/macos/Keybumps/App/AppModel.swift']), { event })).toBe(
      'true'
    )
  })

  it('counts a file renamed out of the checked paths', () => {
    expect(run(changed(['docs/moved.swift', 'apps/macos/old.swift']))).toBe('true')
  })

  // A `tail | grep -q` pipeline under pipefail once could lose this match to SIGPIPE on a long list
  // (seen with GNU tail; macOS's tail doesn't race), which would skip a required suite.
  it('runs the check on a long list whose match comes first', () => {
    const files = [
      '.github/workflows/keybumps-unit-tests.yml',
      ...Array.from(
        { length: 298 },
        (_, i) => `apps/web/src/components/SomeLongEnoughFolderName/AnotherFolder/Component${i}.tsx`
      )
    ]
    expect(files.join('\n').length).toBeGreaterThan(20_000)
    for (let attempt = 0; attempt < 20; attempt++) expect(run(changed(files))).toBe('true')
  })

  it.each([
    ['300 or more files changed', { lines: ['300', 'AGENTS.md'], options: {} }],
    ["the PR's files can't be read", { lines: [], options: { ghExit: 1 } }],
    [
      'it runs for another event (the release gate, a manual run)',
      { lines: changed(['AGENTS.md']), options: { event: 'workflow_call' } }
    ]
  ])('runs the check when %s', (_, { lines, options }) => {
    expect(run(lines, options)).toBe('true')
  })
})
