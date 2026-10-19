import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { ChangelogTimeline } from '@/components/changelog-timeline'
import { compareVersions, releaseNotesFile, releasesFrom } from './changelog'
import { FALLBACK_RELEASE, type LatestRelease } from './latest-release'
import { type IndexedRelease, OLDEST_DOWNLOAD, releaseDownloads } from './release-downloads'

const dmg = (version: string, build: number) =>
  `https://updates.keybumps.app/releases/${build}/Keybumps-${version}.dmg`

const indexed = (version: string, build: number): IndexedRelease => ({
  version,
  build,
  url: dmg(version, build)
})

const index = [
  indexed('0.0.3-beta.29', 4034),
  indexed('0.0.3-beta.28', 4033),
  indexed('0.0.3-beta.13', 4018),
  indexed('0.0.3-beta.12', 4017),
  indexed('0.0.3-beta.6', 4011)
]

const pointer = (version: string, build: number): LatestRelease => ({
  version,
  build,
  dmgURL: dmg(version, build),
  sha256: 'ab'.repeat(32)
})

describe('releaseDownloads', () => {
  it('links each release to its own DMG, and the newest to the current download', () => {
    const current = pointer('0.0.3-beta.29', 4035)
    expect(
      releaseDownloads(['0.0.3-beta.29', '0.0.3-beta.28', '0.0.3-beta.13'], index, current)
    ).toEqual({
      '0.0.3-beta.29': current.dmgURL,
      '0.0.3-beta.28': dmg('0.0.3-beta.28', 4033),
      '0.0.3-beta.13': dmg('0.0.3-beta.13', 4018)
    })
  })

  it('gives a release the index does not list no link, rather than a guessed one', () => {
    const downloads = releaseDownloads(
      ['0.0.3-beta.29', '0.0.3-beta.20', '0.0.3-beta.13'],
      index,
      pointer('0.0.3-beta.29', 4034)
    )
    expect(Object.keys(downloads)).toEqual(['0.0.3-beta.29', '0.0.3-beta.13'])
  })

  it('links nothing older than beta.13, the first notarized build, even when the index lists it', () => {
    expect(OLDEST_DOWNLOAD).toBe('0.0.3-beta.13')
    const downloads = releaseDownloads(
      ['0.0.3-beta.29', '0.0.3-beta.13', '0.0.3-beta.12', '0.0.3-beta.6', '0.0.3-beta.1'],
      index,
      pointer('0.0.3-beta.29', 4034)
    )
    expect(Object.keys(downloads)).toEqual(['0.0.3-beta.29', '0.0.3-beta.13'])
  })

  it("keeps the newest release's own DMG when latest.json names another version", () => {
    // latest.json unreadable (the site's fallback build), or a release whose notes and
    // CHANGELOG.md section merged before it published.
    expect(releaseDownloads(['0.0.3-beta.29'], index, FALLBACK_RELEASE)).toEqual({
      '0.0.3-beta.29': dmg('0.0.3-beta.29', 4034)
    })
    expect(
      releaseDownloads(['0.0.3-beta.30', '0.0.3-beta.29'], index, pointer('0.0.3-beta.29', 4034))
    ).toEqual({ '0.0.3-beta.29': dmg('0.0.3-beta.29', 4034) })
  })

  it('uses the current download only for the newest release', () => {
    const current = pointer('0.0.3-beta.28', 4040)
    expect(releaseDownloads(['0.0.3-beta.29', '0.0.3-beta.28'], index, current)).toEqual({
      '0.0.3-beta.29': dmg('0.0.3-beta.29', 4034),
      '0.0.3-beta.28': dmg('0.0.3-beta.28', 4033)
    })
  })

  it("links the repository's releases from beta.13 on to the fixture's DMGs", () => {
    // The fixture is a copy of the live list, so it can lag the notes: only what it lists counts.
    const root = join(process.cwd(), '..', '..')
    const folder = join(root, 'docs', 'releases')
    const notes = readdirSync(folder)
      .filter(file => releaseNotesFile.test(file))
      .map(file => ({
        version: file.slice(1, -3),
        markdown: readFileSync(join(folder, file), 'utf8')
      }))
    const versions = releasesFrom(notes, readFileSync(join(root, 'CHANGELOG.md'), 'utf8')).map(
      release => release.version
    )
    const fixture: IndexedRelease[] = JSON.parse(
      readFileSync(join(process.cwd(), 'scripts', 'release-index.fixture.json'), 'utf8')
    )
    const listed = fixture.filter(
      release =>
        versions.includes(release.version) && compareVersions(release.version, OLDEST_DOWNLOAD) >= 0
    )
    expect(listed.length).toBeGreaterThan(15)
    const downloads = releaseDownloads(versions, fixture, FALLBACK_RELEASE)
    expect(downloads).toEqual(
      Object.fromEntries(listed.map(release => [release.version, release.url]))
    )
    // Older releases are on the page, and the index lists all but beta.1, but none gets a link.
    for (const version of ['0.0.3-beta.12', '0.0.3-beta.6', '0.0.3-beta.1']) {
      expect(versions).toContain(version)
      expect(downloads[version], version).toBeUndefined()
    }
  })
})

describe('ChangelogTimeline downloads', () => {
  it('shows a Download link, labeled with its version, only on a release that has one', () => {
    const notes = ['0.0.3-beta.29', '0.0.3-beta.20'].map(version => ({
      version,
      markdown: `# Keybumps ${version}\n\nSummary of ${version}.\n\n## Area\n\n- A change.\n`
    }))
    const releases = releasesFrom(
      notes,
      '# Changelog\n\n## [0.0.3-beta.29](https://example.invalid) (2026-10-19)\n'
    )
    expect(releases.map(release => release.version)).toEqual(['0.0.3-beta.29', '0.0.3-beta.20'])
    const html = renderToStaticMarkup(
      createElement(ChangelogTimeline, {
        releases,
        downloads: { '0.0.3-beta.29': dmg('0.0.3-beta.29', 4034) }
      })
    )
    const links = [...html.matchAll(/<a [^>]*class="changelog-download"[^>]*>/g)].map(([tag]) => ({
      href: tag.match(/ href="([^"]*)"/)?.[1],
      label: tag.match(/ aria-label="([^"]*)"/)?.[1]
    }))
    expect(links).toEqual([
      { href: dmg('0.0.3-beta.29', 4034), label: 'Download Keybumps 0.0.3-beta.29' }
    ])
  })
})
