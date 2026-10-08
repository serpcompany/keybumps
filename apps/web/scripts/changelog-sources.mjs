// Copies every release's What's New notes (docs/releases/v*.md) and CHANGELOG.md's version headings
// into src/generated/changelog-sources.json, which /changelog/ imports, so the notes ship inside the
// site's bundle: the deployed Worker has no repository files to read, and Next.js can re-render the
// page there (#424). It runs before every build, typecheck, and dev server; the file isn't committed.
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const web = join(dirname(fileURLToPath(import.meta.url)), '..')
const root = join(web, '..', '..')
const folder = join(root, 'docs', 'releases')

const notes = readdirSync(folder)
  .filter(file => /^v\d+\.\d+\.\d+.*\.md$/.test(file))
  .sort()
  .map(file => ({ version: file.slice(1, -3), markdown: readFileSync(join(folder, file), 'utf8') }))
if (!notes.length) throw new Error(`No release notes in ${folder}`)

// Only the version headings matter: they give each release's date and say which are out.
const changelog = readFileSync(join(root, 'CHANGELOG.md'), 'utf8')
  .split('\n')
  .filter(line => line.startsWith('## '))
  .join('\n')

const output = join(web, 'src', 'generated', 'changelog-sources.json')
mkdirSync(dirname(output), { recursive: true })
writeFileSync(output, `${JSON.stringify({ notes, changelog }, null, 2)}\n`)
