import { readdirSync, readFileSync } from 'node:fs'
import { join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

// Agents may merge a PR that changes only the root AGENTS.md's listed paths. A listed stylesheet
// must therefore hold no class written only for an area the list keeps out: checkout and pricing,
// consent, analytics, and the legal and license pages (SERP verification cadence: "a file that also
// serves an excluded area counts as that area"). This finds each class a listed stylesheet's
// selectors use, then which files set it in a `className`, so a class is judged by where it's
// used, not by its name. A class it can't find any use of fails too, unless listed below with why.
const src = fileURLToPath(new URL('..', import.meta.url))

/** Stylesheets on the root AGENTS.md's listed paths. */
const listedStylesheets = ['app/site.css']

/**
 * Files that render only in an area the list keeps out. Not every file off the list: the header,
 * footer, nav, plugin browser, download link, and site document render on every page.
 */
const excludedArea =
  /^app\/(\(sensitive-url\)|\(analytics\)\/legal|\(analytics\)\/pricing|buy|api)\/|^components\/(analytics|consent-banner|page-shell|pricing-card|strip-query)\.tsx$/

/** Classes only excluded areas use, accepted as shared layout: the only selectors that may use them. */
const acceptedShared: Record<string, { selectors: string[]; why: string }> = {
  first: {
    selectors: ['.section.first'],
    why: "It only removes the first section's top border and sets its padding (#404's review)"
  }
}

/** Classes a listed stylesheet styles that no `className` sets, with why. */
const usedNowhere: Record<string, string> = {
  'plugin-subheading': 'Nothing uses it; delete the rule in a cleanup'
}

function files(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap(entry =>
    entry.isDirectory() ? files(join(directory, entry.name)) : [join(directory, entry.name)]
  )
}

/** The expression after `className=` at `start`: a quoted string or a `{…}` block. */
function attributeValue(source: string, start: number): string {
  if (source[start] === '"') return source.slice(start, source.indexOf('"', start + 1) + 1)
  let depth = 0
  for (let index = start; index < source.length; index++) {
    if (source[index] === '{') depth++
    if (source[index] === '}' && --depth === 0) return source.slice(start, index + 1)
  }
  return ''
}

/** The literal text in an expression: quoted strings, and template literals outside their `${…}`. */
function literalText(expression: string): string[] {
  const found: string[] = []
  for (const match of expression.matchAll(/"([^"]*)"|'([^']*)'/g)) found.push(match[1] ?? match[2])
  for (const template of expression.matchAll(/`((?:[^`\\]|\\.)*)`/g)) {
    found.push(template[1].replace(/\$\{(?:[^{}]|\{[^{}]*\})*\}/g, ' '))
  }
  return found
}

/** Every class name set in a `className` attribute, with the files that set it. */
function classUsers(): Map<string, Set<string>> {
  const users = new Map<string, Set<string>>()
  for (const file of files(src).filter(path => path.endsWith('.tsx'))) {
    const source = readFileSync(file, 'utf8')
    for (const attribute of source.matchAll(/className=/g)) {
      const value = attributeValue(source, (attribute.index ?? 0) + 'className='.length)
      for (const name of literalText(value)
        .flatMap(text => text.split(/\s+/))
        .filter(Boolean)) {
        if (!users.has(name)) users.set(name, new Set())
        users.get(name)?.add(relative(src, file))
      }
    }
  }
  return users
}

/** A stylesheet's selectors, one per comma-separated part, without @-rule preludes. */
function selectors(css: string): string[] {
  const preludes = [...css.matchAll(/([^{};]+)\{/g)].map(match => match[1].trim())
  return preludes
    .filter(prelude => !prelude.startsWith('@'))
    .flatMap(prelude => prelude.split(',').map(s => s.trim()))
}

const users = classUsers()

describe.each(listedStylesheets)('%s (a listed path)', stylesheet => {
  const css = readFileSync(join(src, stylesheet), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '')
  const allSelectors = selectors(css)
  const classes = [
    ...new Set(
      allSelectors.flatMap(selector => [...selector.matchAll(/\.([a-zA-Z][\w-]*)/g)]).map(m => m[1])
    )
  ]

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

  it('styles no class it can find no use of, unless listed with why', () => {
    const unfound = classes.filter(name => !users.has(name) && !(name in usedNowhere))
    expect(
      unfound,
      'Set these in a className the test can read, or list them in usedNowhere'
    ).toEqual([])
  })

  it('uses each accepted shared class only in its accepted selectors', () => {
    for (const [name, { selectors: accepted }] of Object.entries(acceptedShared)) {
      const using = allSelectors.filter(selector =>
        new RegExp(`\\.${name}(?![\\w-])`).test(selector)
      )
      expect(using, name).toEqual(expect.arrayContaining(accepted))
      expect(
        using.filter(selector => !accepted.includes(selector)),
        name
      ).toEqual([])
    }
  })

  it('lists only classes it still styles', () => {
    const listed = [...Object.keys(acceptedShared), ...Object.keys(usedNowhere)]
    expect(listed.filter(name => !classes.includes(name))).toEqual([])
  })
})
