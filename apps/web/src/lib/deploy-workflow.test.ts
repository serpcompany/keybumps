import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

// The SERP ci-workflows standard: a deploy's own build is its build check, so the check job doesn't
// build and each environment builds once; and a deploy goes out only when main has no newer website
// changes (scripts/deploy-tip.sh, tested in deploy-tip.test.ts). This reads the workflows as text (no YAML parser is a dependency here).
const read = (path: string) => readFileSync(fileURLToPath(new URL(path, import.meta.url)), 'utf8')
const deployWorkflow = read('../../../../.github/workflows/web-deploy.yml')
const prWorkflow = read('../../../../.github/workflows/web.yml')
const scripts: Record<string, string> = JSON.parse(read('../../package.json')).scripts

/** A workflow's jobs by id, each the text from its `  <id>:` line to the next job's, without comments. */
function jobs(workflow: string): Record<string, string> {
  const section = workflow.slice(workflow.indexOf('\njobs:\n') + '\njobs:\n'.length)
  const code = section
    .split('\n')
    .filter(line => !line.trim().startsWith('#'))
    .join('\n')
  const found: Record<string, string> = {}
  for (const match of code.matchAll(
    /^ {2}([a-z][\w-]*):\n([\s\S]*?)(?=^ {2}[a-z][\w-]*:\n|$(?![\s\S]))/gm
  )) {
    found[match[1]] = match[2]
  }
  return found
}

/** A command with each `pnpm <script>` replaced by what the script runs, recursively. */
function expand(command: string, depth = 0): string {
  if (depth > 5) throw new Error(`package.json scripts recurse: ${command}`)
  return command.replace(/pnpm (?!exec |install)([\w:-]+)/g, (whole, name: string) =>
    name in scripts ? expand(scripts[name], depth + 1) : whole
  )
}

/** The commands a job or step runs: each `run:` value, including `run: |` blocks. */
function commands(text: string): string {
  const lines = text.split('\n')
  const found: string[] = []
  for (const [index, line] of lines.entries()) {
    const run = line.match(/^(\s*)run: (.*)$/)
    if (!run) continue
    if (run[2] !== '|') {
      found.push(run[2])
      continue
    }
    const indent = run[1].length
    for (const next of lines.slice(index + 1)) {
      if (next.trim() && next.search(/\S/) <= indent) break
      found.push(next)
    }
  }
  return expand(found.join('\n'))
}

/** How many times a job or step builds the site. */
function builds(text: string): number {
  return commands(text).match(/opennextjs-cloudflare build|next build/g)?.length ?? 0
}

/** The text of one step, from its `- name:` line to the next step's. */
function step(job: string, name: string): string {
  const start = job.indexOf(`- name: ${name}\n`)
  expect(start, `step "${name}"`).toBeGreaterThanOrEqual(0)
  const next = job.indexOf('- name: ', start + 1)
  return job.slice(start, next === -1 ? undefined : next)
}

const deploy = jobs(deployWorkflow)

describe('web-deploy.yml', () => {
  it('has the check, staging, and production jobs', () => {
    expect(Object.keys(deploy)).toEqual(['check', 'staging', 'production'])
  })

  it("doesn't build in the check job: the deploy builds are the build check", () => {
    expect(builds(deploy.check)).toBe(0)
    expect(deploy.check).toContain('run: pnpm check:code')
  })

  it.each(['staging', 'production'])('builds once in the %s job', env => {
    expect(builds(deploy[env])).toBe(1)
  })

  it.each(['staging', 'production'])(
    'deploys and smoke-tests %s only when the tip check allows it, checked after the build',
    env => {
      const job = deploy[env]
      expect(step(job, "Check main's tip")).toMatch(
        /id: tip\n[\s\S]*run: \.\/scripts\/deploy-tip\.sh/
      )
      for (const name of ['Deploy', 'Smoke test']) {
        expect(step(job, name)).toContain("if: steps.tip.outputs.deploy == 'true'")
      }
      expect(commands(step(job, 'Build'))).not.toContain('deploy')
      expect(builds(step(job, 'Deploy'))).toBe(0)
      const order = ['Build', "Check main's tip", 'Deploy', 'Smoke test'].map(name =>
        job.indexOf(`- name: ${name}\n`)
      )
      expect(order).toEqual([...order].sort((a, b) => a - b))
    }
  )

  it('runs production only when staging deployed', () => {
    expect(deploy.staging).toMatch(/deployed: \$\{\{ steps\.tip\.outputs\.deploy \}\}/)
    expect(deploy.production).toContain("needs.staging.outputs.deployed == 'true'")
  })
})

describe('web.yml', () => {
  it('still builds on pull requests, where no deploy build checks the tree', () => {
    const pr = jobs(prWorkflow)
    expect(Object.values(pr).reduce((total, job) => total + builds(job), 0)).toBe(1)
  })

  it('runs the website check on the release notes and CHANGELOG.md /changelog/ is built from, not the runbooks', () => {
    const pattern = new RegExp(prWorkflow.match(/pr-touches\.sh '([^']+)'/)?.[1] ?? '$^')
    expect(pattern.test('docs/releases/v0.0.3-beta.24.md')).toBe(true)
    expect(pattern.test('CHANGELOG.md')).toBe(true)
    expect(pattern.test('docs/releases/sparkle-update-operations.md')).toBe(false)
  })

  it('starts a Web deploy on main only after a release publishes, with only the Actions permission', () => {
    const website = jobs(read('../../../../.github/workflows/release-please.yml')).website ?? ''
    expect(website).toMatch(/^ {4}needs: release$/m)
    expect(website).not.toMatch(/^ {4}if:/m)
    expect(website).toMatch(/permissions:\n {6}actions: write\n {4}steps:/)
    expect(website).toContain(
      'gh workflow run web-deploy.yml --repo "$GITHUB_REPOSITORY" --ref main'
    )
    expect(deployWorkflow).toMatch(/\n {2}workflow_dispatch:\n/)
    expect(deployWorkflow).not.toContain('workflow_call')
  })
})
