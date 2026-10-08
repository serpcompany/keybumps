import { readdirSync, readFileSync } from 'node:fs'
import { join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

// Agents may merge a PR that changes only the root AGENTS.md's listed paths. A listed stylesheet
// must therefore hold no rule written only for an area the list keeps out: checkout and pricing,
// consent, analytics, and the legal and license pages (SERP verification cadence: "a file that also
// serves an excluded area counts as that area"). This finds each class a listed stylesheet styles,
// then where the app uses it, so a rule is judged by its users, not by its name.
const src = fileURLToPath(new URL('..', import.meta.url))

/** Stylesheets on the root AGENTS.md's listed paths. */
const listedStylesheets = ['app/site.css']

/** Files of the areas the list keeps out. Keep in step with the root AGENTS.md. */
const excludedArea =
  /^app\/(\(sensitive-url\)|\(analytics\)\/legal|\(analytics\)\/pricing|buy|api)\/|^components\/(analytics|consent-banner|download-link|page-shell|pricing-card|site-document|strip-query)\.tsx$/

/** Classes only excluded areas use that review accepted as shared layout, with why. */
const acceptedShared: Record<string, string> = {
  first:
    "`.section.first` only removes the first section's top border and sets its padding (#404's review)"
}

function files(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap(entry =>
    entry.isDirectory() ? files(join(directory, entry.name)) : [join(directory, entry.name)]
  )
}

/** Every class name in a `className` attribute, with the files that use it. */
function classUsers(): Map<string, Set<string>> {
  const users = new Map<string, Set<string>>()
  for (const file of files(src).filter(path => path.endsWith('.tsx'))) {
    const source = readFileSync(file, 'utf8')
    for (const attribute of source.matchAll(/className=("[^"]*"|\{[^}]*\})/g)) {
      for (const literal of attribute[1].matchAll(/["'`]([^"'`]*)["'`]/g)) {
        for (const name of literal[1].split(/\s+/).filter(Boolean)) {
          if (!users.has(name)) users.set(name, new Set())
          users.get(name)?.add(relative(src, file))
        }
      }
    }
  }
  return users
}

const users = classUsers()

describe.each(listedStylesheets)('%s (a listed path)', stylesheet => {
  const css = readFileSync(join(src, stylesheet), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '')
  const classes = [...new Set([...css.matchAll(/\.([a-zA-Z][\w-]*)/g)].map(match => match[1]))]

  it('styles no class that only excluded areas use', () => {
    const onlyExcluded = classes.filter(name => {
      const used = [...(users.get(name) ?? [])]
      return (
        used.length > 0 && used.every(file => excludedArea.test(file)) && !(name in acceptedShared)
      )
    })
    expect(
      onlyExcluded,
      'Move these rules to the area’s own stylesheet (legal.css, pricing.css, consent.css)'
    ).toEqual([])
  })

  it('lists only accepted classes it still styles', () => {
    expect(Object.keys(acceptedShared).filter(name => !classes.includes(name))).toEqual([])
  })
})
