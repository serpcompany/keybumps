import { readdirSync, readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

// main requires these checks, and a required check must report on every pull request. A workflow
// skipped by a `paths:` filter never reports, which would block every PR that doesn't touch its
// files. So each workflow runs on all PRs: its `changes` job decides whether the slow job runs, and
// a last gate job, which carries the required check's name, passes only if the suite passed or was
// skipped because the PR touches none of its files (SERP ci-workflows: "Skip docs-only changes
// inside the workflow").
const workflows = [
  {
    file: 'keybumps-unit-tests.yml',
    job: 'unit',
    gate: 'unit-tests',
    check: 'Unit tests (KeybumpsTests)'
  },
  { file: 'keybumps-ui-tests.yml', job: 'ui', gate: 'ui-tests', check: 'UI tests (with retries)' },
  { file: 'web.yml', job: 'check', gate: 'website-check', check: 'Website check (pnpm check)' }
]

const read = (name: string) =>
  readFileSync(
    fileURLToPath(new URL(`../../../../.github/workflows/${name}`, import.meta.url)),
    'utf8'
  )

/** One job's text, from its `  <id>:` line to the next job's. */
function job(workflow: string, id: string): string {
  const start = workflow.indexOf(`\n  ${id}:\n`)
  expect(start, `job ${id}`).toBeGreaterThanOrEqual(0)
  const next = workflow.slice(start + 1).search(/\n {2}[a-z][\w-]*:\n/)
  return next === -1 ? workflow.slice(start) : workflow.slice(start, start + 1 + next)
}

describe.each(workflows)('$file', ({ file, job: slow, gate, check }) => {
  const workflow = read(file)
  const trigger = workflow.slice(workflow.indexOf('\non:\n'), workflow.indexOf('\npermissions:'))

  it('runs on every pull request to main, with no paths filter', () => {
    expect(trigger).toContain('pull_request:\n    branches: [main]')
    expect(trigger).not.toMatch(/^\s+paths(-ignore)?:/m)
  })

  it('decides only on pull requests, in a changes job, whether the slow job runs', () => {
    const changes = job(workflow, 'changes')
    expect(changes).toContain("if: github.event_name == 'pull_request'")
    expect(changes).toContain('run: .github/scripts/pr-touches.sh ')
    const suite = job(workflow, slow)
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

  it('covers its own workflow file and the script in its pattern', () => {
    const pattern = new RegExp(workflow.match(/pr-touches\.sh '([^']+)'/)?.[1] ?? '$^')
    expect(pattern.test(`.github/workflows/${file}`)).toBe(true)
    expect(pattern.test('.github/scripts/pr-touches.sh')).toBe(true)
    expect(
      pattern.test(
        file === 'web.yml' ? 'apps/web/src/app/site.css' : 'apps/macos/Keybumps/App/AppModel.swift'
      )
    ).toBe(true)
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

it('gives no other job a required check name, which could report it without running the suite', () => {
  const required = workflows.map(({ check }) => check)
  const dir = fileURLToPath(new URL('../../../../.github/workflows/', import.meta.url))
  for (const file of readdirSync(dir).filter(name => name.endsWith('.yml'))) {
    const names = [...read(file).matchAll(/^ {4}name: (.+)$/gm)].map(match => match[1].trim())
    const own = workflows.find(workflow => workflow.file === file)?.check
    for (const name of names.filter(name => required.includes(name))) {
      expect(name, `${file} has a job named "${name}"`).toBe(own)
    }
  }
})
