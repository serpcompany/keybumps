import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  changelogDates,
  compareVersions,
  parseNotes,
  plainText,
  pluginsNamed,
  releaseNotesFile,
  releasesFrom,
  searchReleases
} from './changelog'

const changelog = `# Changelog

## [0.0.3-beta.13](https://github.com/serpcompany/keybumps/compare/v0.0.3-beta.12...v0.0.3-beta.13) (2026-10-02)

### Fixes

* something

## [0.0.3-beta.2](https://github.com/serpcompany/keybumps/compare/v0.0.3-beta.1...v0.0.3-beta.2) (2026-09-20)
`

const note = (version: string, body = '- A change.') =>
  ({
    version,
    markdown: `# Keybumps ${version}\n\nSummary of ${version}.\n\n## Area\n\n${body}\n`
  }) as const

const root = join(process.cwd(), '..', '..')

function realNotes() {
  const folder = join(root, 'docs', 'releases')
  return readdirSync(folder)
    .filter(file => releaseNotesFile.test(file))
    .map(file => ({
      version: file.slice(1, -3),
      markdown: readFileSync(join(folder, file), 'utf8')
    }))
}

function realReleases() {
  return releasesFrom(realNotes(), readFileSync(join(root, 'CHANGELOG.md'), 'utf8'))
}

describe('changelog versions', () => {
  it('orders versions as releases do: numbers by value, prereleases below their release', () => {
    const ordered = ['0.0.2', '0.0.3-beta.2', '0.0.3-beta.12', '0.0.3-rc.1', '0.0.3', '0.1.0']
    expect([...ordered].reverse().sort(compareVersions)).toEqual(ordered)
  })

  it('reads each release date from release-please headings', () => {
    expect(changelogDates(changelog)).toEqual(
      new Map([
        ['0.0.3-beta.13', '2026-10-02'],
        ['0.0.3-beta.2', '2026-09-20']
      ])
    )
  })
})

describe('changelog notes', () => {
  it('parses the summary, a callout, sections, and their change counts', () => {
    const parsed = parseNotes(`# Keybumps 0.0.3-beta.12

This beta adds **Snippets**.

> **Heads up.** Read this:
> - **Permissions:** allow them again.
>
> You also get everything from before.

## Snippets (new)

- Save text you reuse.
- Open the Snippets tab (⌘5).

### Fixes

- One fix.
`)
    expect(parsed.summary).toBe('This beta adds **Snippets**.')
    expect(parsed.intro).toEqual([
      {
        kind: 'callout',
        blocks: [
          { kind: 'paragraph', text: '**Heads up.** Read this:' },
          { kind: 'list', items: ['**Permissions:** allow them again.'] },
          { kind: 'paragraph', text: 'You also get everything from before.' }
        ]
      }
    ])
    expect(parsed.sections.map(s => [s.heading, s.kind, s.changes])).toEqual([
      ['Snippets (new)', 'new', 2],
      ['Fixes', 'fix', 1]
    ])
  })

  it('turns inline Markdown into plain text for search', () => {
    expect(
      plainText(
        'Turn off **Put the clipboard back** in `Settings`, see [the policy](https://keybumps.app/legal/privacy/).'
      )
    ).toBe('Turn off Put the clipboard back in Settings, see the policy.')
  })

  it('tags the plugins a release names, including the words notes use for them', () => {
    expect(
      pluginsNamed('The Translate tab saves translations, and Dictation pastes.').map(p => p.slug)
    ).toEqual(['dictation', 'translation'])
    expect(pluginsNamed('your clipboard is the way you left it').map(p => p.slug)).toEqual([])
  })
})

describe('released versions', () => {
  it('lists only versions up to the newest CHANGELOG.md section, newest first, with dates', () => {
    const releases = releasesFrom(
      [note('0.0.3-beta.1'), note('0.0.3-beta.14'), note('0.0.3-beta.2'), note('0.0.3-beta.13')],
      changelog
    )
    expect(releases.map(r => r.version)).toEqual(['0.0.3-beta.13', '0.0.3-beta.2', '0.0.3-beta.1'])
    expect(releases[0]).toMatchObject({
      id: 'v0-0-3-beta-13',
      date: '2026-10-02',
      dateLabel: 'Oct 2, 2026',
      monthLabel: 'October 2026',
      summary: 'Summary of 0.0.3-beta.13.'
    })
    expect(releases[2]).toMatchObject({ date: null, dateLabel: '', monthLabel: 'Earlier releases' })
  })

  it('keeps every word a release could be searched by: version, dates, notes, and plugin tags', () => {
    const [release] = releasesFrom(
      [note('0.0.3-beta.13', '- Fixed the **Clipboard tab**.')],
      changelog
    )
    for (const term of [
      'beta.13',
      'oct 2',
      'october 2',
      'october 2026',
      '2026-10-02',
      'fixed',
      'area',
      'clipboard history'
    ]) {
      expect(release.searchText).toContain(term)
    }
  })

  it('reads a version, a date or month, or a plugin name exactly, and anything else as words', () => {
    const releases = realReleases()
    const versions = (query: string) => searchReleases(releases, query).shown.map(r => r.version)
    expect(versions('beta.1')).toEqual(['0.0.3-beta.1'])
    expect(versions('0.0.3-beta.12')).toEqual(['0.0.3-beta.12'])
    expect(versions('0.0.3')).toEqual(releases.map(r => r.version))
    expect(versions('Oct 5')).toEqual(['0.0.3-beta.16', '0.0.3-beta.15', '0.0.3-beta.14'])
    expect(versions('Oct 5 2026')).toEqual(versions('Oct 5'))
    expect(versions('October 5, 2026')).toEqual(versions('Oct 5'))
    expect(versions('2026-10-05')).toEqual(versions('Oct 5'))
    expect(versions('Oct 3')).toEqual([])
    expect(versions('October')).toEqual(
      releases.filter(r => r.monthLabel === 'October 2026').map(r => r.version)
    )
    for (const r of releases.filter(r => r.plugins.length)) {
      for (const tag of r.plugins) expect(versions(tag.name)).toContain(r.version)
    }
    expect(versions('Timer')).toEqual(
      releases.filter(r => r.plugins.some(p => p.slug === 'timer')).map(r => r.version)
    )
  })

  it('lets text searches only narrow as you type, and finds words inside longer words', () => {
    const releases = realReleases()
    const count = (query: string) => searchReleases(releases, query).shown.length
    expect(count('set')).toBeGreaterThanOrEqual(count('sett'))
    expect(count('sett')).toBeGreaterThanOrEqual(count('setting'))
    expect(count('setting')).toBeGreaterThanOrEqual(count('settings'))
    expect(count('fix')).toBeGreaterThan(1)
    const permission = searchReleases(releases, 'permission').shown.map(r => r.version)
    expect(permission).toEqual(expect.arrayContaining(['0.0.3-beta.12', '0.0.3-beta.13']))
    expect(searchReleases(releases, 'rings alarm').terms).toEqual(['rings', 'alarm'])
  })

  it('counts a section written as prose by its paragraphs, and otherwise only its bullets', () => {
    const { sections } = parseNotes(
      '# T\n\nS.\n\n## Prose\n\nOne.\n\nTwo.\n\n## Mixed\n\nIntro.\n\n- A.\n- B.\n'
    )
    expect(sections.map(section => section.changes)).toEqual([2, 2])
  })

  it('fails without a dated CHANGELOG.md heading, rather than showing unreleased notes', () => {
    expect(() => releasesFrom([note('0.0.3-beta.24')], '# Changelog\n')).toThrow(
      /no dated release headings/
    )
  })

  it('reads every release in the repository: newest first, none newer than CHANGELOG.md, each with a summary and a unique anchor', () => {
    const history = readFileSync(join(root, 'CHANGELOG.md'), 'utf8')
    const newest = [...changelogDates(history).keys()].sort(compareVersions).at(-1) as string
    const releases = realReleases()
    const versions = releases.map(r => r.version)
    expect(versions).toEqual(
      realNotes()
        .map(n => n.version)
        .filter(v => compareVersions(v, newest) <= 0)
        .sort(compareVersions)
        .reverse()
    )
    expect(new Set(releases.map(r => r.id)).size).toBe(releases.length)
    for (const release of releases) expect(release.summary).not.toBe('')
  })
})
