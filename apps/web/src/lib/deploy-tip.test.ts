import { spawnSync } from 'node:child_process'
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { afterAll, describe, expect, it } from 'vitest'

// scripts/deploy-tip.sh decides whether a web-deploy run deploys: only when main has no website
// changes newer than the run's commit (each of those starts its own run). It runs here with a stub
// `gh` that prints a canned compare result, never the real API.
const script = fileURLToPath(new URL('../../scripts/deploy-tip.sh', import.meta.url))
const workflow = readFileSync(
  fileURLToPath(new URL('../../../../.github/workflows/web-deploy.yml', import.meta.url)),
  'utf8'
)
const scratch = mkdtempSync(join(tmpdir(), 'deploy-tip-'))
writeFileSync(
  join(scratch, 'gh'),
  '#!/usr/bin/env bash\nprintf "%s" "$FAKE_GH_OUTPUT"\nexit "$FAKE_GH_EXIT"\n'
)
chmodSync(join(scratch, 'gh'), 0o755)
afterAll(() => rmSync(scratch, { recursive: true, force: true }))

/** Runs the script against a compare result: its status, file count, and file names. */
function run(lines: string[], ghExit = 0): { status: number | null; deploy: string | undefined } {
  const output = join(scratch, `output-${Math.random()}`)
  writeFileSync(output, '')
  const result = spawnSync('bash', [script], {
    env: {
      PATH: `${scratch}:${process.env.PATH}`,
      FAKE_GH_OUTPUT: lines.join('\n'),
      FAKE_GH_EXIT: String(ghExit),
      GITHUB_REPOSITORY: 'example/repo',
      GITHUB_SHA: 'abc1234def',
      GITHUB_OUTPUT: output
    },
    encoding: 'utf8'
  })
  return {
    status: result.status,
    deploy: readFileSync(output, 'utf8').match(/^deploy=(\w+)$/m)?.[1]
  }
}

const ahead = (files: string[]) => ['ahead', String(files.length), ...files]

describe('scripts/deploy-tip.sh', () => {
  it('deploys when main is this commit', () => {
    expect(run(['identical', '0'])).toEqual({ status: 0, deploy: 'true' })
  })

  it('deploys when main moved on only outside the website (a Mac merge, a release)', () => {
    expect(run(ahead(['CHANGELOG.md', 'apps/macos/Keybumps/App/AppModel.swift']))).toEqual({
      status: 0,
      deploy: 'true'
    })
  })

  it.each([
    ['a site file', ['apps/macos/x.swift', 'apps/web/src/app/site.css']],
    ['the deploy workflow', ['.github/workflows/web-deploy.yml']],
    ['a file renamed out of the site', ['docs/moved.md', 'apps/web/old.ts']]
  ])('skips when main has a newer website change: %s', (_, files) => {
    expect(run(ahead(files))).toEqual({ status: 0, deploy: 'false' })
  })

  // A `tail | grep -q` pipeline under pipefail once lost this match: grep stopping early let SIGPIPE
  // kill tail on lists of about 18 KB (seen with GNU tail; macOS's tail doesn't race), which read as
  // "no website changes" and deployed. Keep the list near the 300-file cap and well over that size.
  it('skips on a long list whose website change comes first', () => {
    const files = [
      '.github/workflows/web-deploy.yml',
      ...Array.from(
        { length: 298 },
        (_, i) => `apps/macos/Keybumps/Capabilities/LongEnoughFolderName/File${i}.swift`
      )
    ]
    expect(files.join('\n').length).toBeGreaterThan(20_000)
    for (let attempt = 0; attempt < 20; attempt++) {
      expect(run(ahead(files))).toEqual({ status: 0, deploy: 'false' })
    }
  })

  it.each([
    ['main is 300 or more files ahead', ['ahead', '300', 'apps/macos/x.swift']],
    ["this commit isn't on main", ['diverged', '1', 'apps/web/x.ts']],
    ['main is behind this commit', ['behind', '0']]
  ])('fails, deploying nothing, when %s', (_, lines) => {
    expect(run(lines)).toEqual({ status: 1, deploy: undefined })
  })

  it("fails, deploying nothing, when main can't be read", () => {
    expect(run([], 1)).toEqual({ status: 1, deploy: undefined })
  })

  it("treats exactly the workflow's push paths as the website", () => {
    const site = new RegExp(readFileSync(script, 'utf8').match(/^site='(.+)'$/m)?.[1] ?? '$^')
    const paths =
      workflow.match(/push:\n {4}branches: \[main\]\n {4}paths:\n((?: {6}- .+\n)+)/)?.[1] ?? ''
    const listed = paths.match(/- (.+)/g)?.map(line => line.slice(2)) ?? []
    expect(listed).toEqual(['apps/web/**', '.github/workflows/web-deploy.yml'])
    expect(site.test('apps/web/src/app/page.tsx')).toBe(true)
    expect(site.test('.github/workflows/web-deploy.yml')).toBe(true)
    expect(site.test('.github/workflows/web.yml')).toBe(false)
    expect(site.test('apps/macos/Keybumps/App/AppModel.swift')).toBe(false)
  })
})
