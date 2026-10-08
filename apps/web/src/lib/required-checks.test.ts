import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

// main requires these workflows' checks, and a required check must report on every pull request.
// A workflow skipped by a `paths:` filter never reports, which would block every PR that doesn't
// touch its files. So each runs on all PRs, and its `changes` job decides whether the slow job runs
// (SERP ci-workflows: "Skip docs-only changes inside the workflow").
const workflows = {
  'keybumps-unit-tests.yml': 'unit',
  'keybumps-ui-tests.yml': 'ui',
  'web.yml': 'check'
}

const read = (name: string) =>
  readFileSync(
    fileURLToPath(new URL(`../../../../.github/workflows/${name}`, import.meta.url)),
    'utf8'
  )

describe.each(Object.entries(workflows))('%s', (name, slowJob) => {
  const workflow = read(name)
  const trigger = workflow.slice(workflow.indexOf('\non:\n'), workflow.indexOf('\npermissions:'))

  it('runs on every pull request to main, with no paths filter', () => {
    expect(trigger).toContain('pull_request:\n    branches: [main]')
    expect(trigger).not.toMatch(/^\s+paths(-ignore)?:/m)
  })

  it('decides in a changes job whether its slow job runs, and runs it when unsure', () => {
    expect(workflow).toContain('run: .github/scripts/pr-touches.sh ')
    const job = workflow.slice(workflow.indexOf(`\n  ${slowJob}:\n`))
    expect(job).toMatch(/^ {4}needs: changes$/m)
    expect(job).toMatch(/if: \$\{\{ !cancelled\(\) && needs\.changes\.outputs\.run != 'false' \}\}/)
  })

  it('covers its own workflow file and the script in its pattern', () => {
    const pattern = workflow.match(/pr-touches\.sh '([^']+)'/)?.[1] ?? ''
    const matches = (path: string) => new RegExp(pattern).test(path)
    expect(matches(`.github/workflows/${name}`)).toBe(true)
    expect(matches('.github/scripts/pr-touches.sh')).toBe(true)
    expect(
      matches(
        name === 'web.yml' ? 'apps/web/src/app/site.css' : 'apps/macos/Keybumps/App/AppModel.swift'
      )
    ).toBe(true)
    expect(matches('AGENTS.md')).toBe(false)
  })
})
