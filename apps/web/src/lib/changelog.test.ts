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

  it('finds a whole phrase first, so a date, version, or plugin means just that, then every word', () => {
    const releases = [
      { id: 'a', searchText: '0.0.3-beta.1 oct 5, 2026 oct 5 a timer rings' },
      { id: 'b', searchText: '0.0.3-beta.12 oct 25, 2026 oct 25 5 changes in october' },
      { id: 'c', searchText: '0.0.3-beta.13 oct 2, 2026 oct 2 clipboard history' }
    ]
    const ids = (query: string) => searchReleases(releases, query).shown.map(r => r.id)
    expect(ids('Oct 5')).toEqual(['a'])
    expect(ids('oct  2')).toEqual(['c'])
    expect(ids('beta.1')).toEqual(['a'])
    expect(ids('Clipboard History')).toEqual(['c'])
    expect(ids('rings timer')).toEqual(['a'])
    expect(ids('tim')).toEqual(['a'])
    expect(ids('')).toEqual(['a', 'b', 'c'])
    expect(searchReleases(releases, 'Oct 5').terms).toEqual(['oct 5'])
    expect(searchReleases(releases, 'rings timer').terms).toEqual(['rings', 'timer'])
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
    const root = join(process.cwd(), '..', '..')
    const folder = join(root, 'docs', 'releases')
    const notes = readdirSync(folder)
      .filter(file => releaseNotesFile.test(file))
      .map(file => ({
        version: file.slice(1, -3),
        markdown: readFileSync(join(folder, file), 'utf8')
      }))
    const history = readFileSync(join(root, 'CHANGELOG.md'), 'utf8')
    const newest = [...changelogDates(history).keys()].sort(compareVersions).at(-1) as string
    const releases = releasesFrom(notes, history)
    const versions = releases.map(r => r.version)
    expect(versions).toEqual(
      notes
        .map(n => n.version)
        .filter(v => compareVersions(v, newest) <= 0)
        .sort(compareVersions)
        .reverse()
    )
    expect(versions[0]).toBe(newest)
    expect(new Set(releases.map(r => r.id)).size).toBe(releases.length)
    for (const release of releases) expect(release.summary).not.toBe('')
  })
})
