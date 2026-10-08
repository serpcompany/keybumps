import { type IconTint, type PluginSystemImage, plugins } from './plugins'

/**
 * The /changelog/ page's data (#424): every release's What's New notes, docs/releases/v<version>.md,
 * the same notes the Mac app shows in What's New and Settings › Changelog.
 * scripts/changelog-sources.mjs copies them, with CHANGELOG.md's headings, into the site's bundle
 * when it builds, because the Worker has no repository files to read. A version shows once
 * release-please has written its CHANGELOG.md section, which also gives its date, so notes merged
 * ahead of their release (they go in before the release PR) don't show early.
 */

export type NoteBlock =
  | { kind: 'paragraph'; text: string }
  | { kind: 'list'; items: string[] }
  | { kind: 'callout'; blocks: NoteBlock[] }

export type ReleaseSection = {
  heading: string
  blocks: NoteBlock[]
  /** How many changes it lists: its bullets and paragraphs. */
  changes: number
  /** Fixes, new things, or anything else, for the tag beside its heading. */
  kind: 'fix' | 'new' | 'area'
}

export type ReleasePlugin = {
  slug: string
  name: string
  systemImage: PluginSystemImage
  tint: IconTint
}

export type Release = {
  version: string
  /** Its anchor on the page, such as v0-0-3-beta-24. */
  id: string
  /** Its release date from CHANGELOG.md (YYYY-MM-DD), when it has one. */
  date: string | null
  /** "Oct 8, 2026", or empty without a date. */
  dateLabel: string
  /** "October 2026", or "Earlier releases" without a date. */
  monthLabel: string
  /** The notes' first paragraph, shown as the release's heading. */
  summary: string
  /** Anything else above the first section, such as a callout. */
  intro: NoteBlock[]
  sections: ReleaseSection[]
  /** The plugins its notes name, in src/lib/plugins.ts order. */
  plugins: ReleasePlugin[]
  /** Everything the page's search matches, in lowercase: version, dates, and the notes as text. */
  searchText: string
}

const MONTHS = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December'
]

/** Other words the notes use for a plugin, so its tag shows on the releases that change it. */
const pluginAliases: Record<string, readonly string[]> = {
  'clipboard-history': ['Clipboard tab'],
  'screenshot-tools': ['Screenshots tab', 'Screenshot Editor'],
  'shortcut-coach': ['Keyboard Shortcutter'],
  snippets: ['Snippet', 'Snippets tab'],
  'emoji-picker': ['Emoji'],
  translation: ['Translate tab', 'Translate']
}

/** Compares two Keybumps versions the way SemVer orders releases: beta.2 before beta.12. */
export function compareVersions(a: string, b: string): number {
  const parse = (version: string) => {
    const [core, ...rest] = version.split('-')
    return { core: core.split('.').map(Number), pre: rest.length ? rest.join('-').split('.') : [] }
  }
  const left = parse(a)
  const right = parse(b)
  for (let i = 0; i < Math.max(left.core.length, right.core.length); i++) {
    const difference = (left.core[i] ?? 0) - (right.core[i] ?? 0)
    if (difference !== 0) return difference
  }
  // A release ranks above its prereleases.
  if (!left.pre.length || !right.pre.length) return right.pre.length - left.pre.length
  for (let i = 0; i < Math.min(left.pre.length, right.pre.length); i++) {
    const [x, y] = [left.pre[i], right.pre[i]]
    if (x === y) continue
    const [nx, ny] = [Number(x), Number(y)]
    if (Number.isInteger(nx) && Number.isInteger(ny)) return nx - ny
    if (Number.isInteger(nx)) return -1
    if (Number.isInteger(ny)) return 1
    return x < y ? -1 : 1
  }
  return left.pre.length - right.pre.length
}

/** Each version's date from release-please's CHANGELOG.md headings, such as `## [0.0.3-beta.23](…) (2026-10-08)`. */
export function changelogDates(changelog: string): Map<string, string> {
  const dates = new Map<string, string>()
  for (const match of changelog.matchAll(
    /^##\s+\[?(\d+\.\d+\.\d+[^\]\s(]*)\]?(?:\([^)]*\))?\s+\((\d{4}-\d{2}-\d{2})\)/gm
  )) {
    dates.set(match[1], match[2])
  }
  return dates
}

/** Inline Markdown as plain text: **bold**, `code`, and [links](…) keep only their words. */
export function plainText(markdown: string): string {
  return markdown
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
    .replace(/\*\*([^*]+)\*\*/g, '$1')
    .replace(/`([^`]+)`/g, '$1')
}

/** Paragraphs and `- ` lists, separated by blank lines. */
function parseBlocks(lines: string[]): NoteBlock[] {
  const blocks: NoteBlock[] = []
  let paragraph: string[] = []
  let list: string[] | null = null
  const flush = () => {
    if (paragraph.length) blocks.push({ kind: 'paragraph', text: paragraph.join(' ') })
    if (list) blocks.push({ kind: 'list', items: list })
    paragraph = []
    list = null
  }
  for (const raw of lines) {
    const line = raw.trim()
    if (!line) {
      flush()
    } else if (line.startsWith('- ')) {
      if (paragraph.length) {
        blocks.push({ kind: 'paragraph', text: paragraph.join(' ') })
        paragraph = []
      }
      list ??= []
      list.push(line.slice(2))
    } else {
      if (list) flush()
      paragraph.push(line)
    }
  }
  flush()
  return blocks
}

/** Blocks, with each run of `>` lines as one callout (a blank line ends it). */
function parseSection(lines: string[]): NoteBlock[] {
  const blocks: NoteBlock[] = []
  let run: string[] = []
  let quoted = false
  const flush = () => {
    if (run.length) {
      if (quoted) blocks.push({ kind: 'callout', blocks: parseBlocks(run) })
      else blocks.push(...parseBlocks(run))
    }
    run = []
  }
  for (const raw of lines) {
    const isQuote = /^\s*>/.test(raw)
    if (!raw.trim()) {
      if (quoted) {
        flush()
        quoted = false
      } else {
        run.push(raw)
      }
      continue
    }
    if (isQuote !== quoted) {
      flush()
      quoted = isQuote
    }
    run.push(isQuote ? raw.replace(/^\s*>\s?/, '') : raw)
  }
  flush()
  return blocks
}

/** A section's bullets, or its paragraphs when it has no bullets (a note written as prose). */
function countChanges(blocks: NoteBlock[]): number {
  const bullets = blocks.reduce(
    (sum, block) => sum + (block.kind === 'list' ? block.items.length : 0),
    0
  )
  return bullets || blocks.filter(block => block.kind === 'paragraph').length
}

function blockText(block: NoteBlock): string {
  if (block.kind === 'paragraph') return block.text
  if (block.kind === 'list') return block.items.join(' ')
  return block.blocks.map(blockText).join(' ')
}

/** One release's notes: the title line, then a summary paragraph, then `##` or `###` sections. */
export function parseNotes(markdown: string): Pick<Release, 'summary' | 'intro' | 'sections'> {
  const groups: { heading: string | null; lines: string[] }[] = [{ heading: null, lines: [] }]
  for (const raw of markdown.split(/\r?\n/)) {
    const line = raw.trim()
    if (/^#\s/.test(line)) continue
    const heading = /^#{2,3}\s+(.+)$/.exec(line)
    if (heading) groups.push({ heading: heading[1].trim(), lines: [] })
    else groups[groups.length - 1].lines.push(raw)
  }
  const intro = parseSection(groups[0].lines)
  const first = intro.findIndex(block => block.kind === 'paragraph')
  const summary = first >= 0 ? (intro.splice(first, 1)[0] as { text: string }).text : ''
  const sections = groups.slice(1).map(group => {
    const heading = group.heading ?? ''
    const blocks = parseSection(group.lines)
    const kind: ReleaseSection['kind'] = /fix/i.test(heading)
      ? 'fix'
      : /\bnew\b/i.test(heading)
        ? 'new'
        : 'area'
    return { heading, blocks, changes: countChanges(blocks), kind }
  })
  return { summary, intro, sections }
}

function escapeRegExp(text: string) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

/** The plugins a release's notes name, by name or by the words in `pluginAliases`. */
export function pluginsNamed(text: string): ReleasePlugin[] {
  return plugins
    .filter(plugin => {
      const names = [plugin.name, ...(pluginAliases[plugin.slug] ?? [])].map(escapeRegExp)
      return new RegExp(`\\b(?:${names.join('|')})\\b`).test(text)
    })
    .map(({ slug, name, systemImage, tint }) => ({ slug, name, systemImage, tint }))
}

/**
 * Every released version's notes, newest first. `notes` holds each docs/releases file's version and
 * text; a version newer than CHANGELOG.md's newest section hasn't been released yet and is left out.
 */
export function releasesFrom(
  notes: readonly { version: string; markdown: string }[],
  changelog: string
): Release[] {
  const dates = changelogDates(changelog)
  const newest = [...dates.keys()].sort(compareVersions).at(-1)
  // Without it, unreleased notes would show: fail the build instead.
  if (!newest) throw new Error('CHANGELOG.md has no dated release headings')
  return notes
    .filter(note => compareVersions(note.version, newest) <= 0)
    .sort((a, b) => compareVersions(b.version, a.version))
    .map(note => {
      const parsed = parseNotes(note.markdown)
      const date = dates.get(note.version) ?? null
      const [year, month, day] = date ? date.split('-').map(Number) : []
      const dateLabel = date ? `${MONTHS[month - 1].slice(0, 3)} ${day}, ${year}` : ''
      const monthLabel = date ? `${MONTHS[month - 1]} ${year}` : 'Earlier releases'
      const text = plainText(
        [
          parsed.summary,
          ...parsed.intro.map(blockText),
          ...parsed.sections.map(
            section => `${section.heading} ${section.blocks.map(blockText).join(' ')}`
          )
        ].join(' ')
      )
      const dateWords = date
        ? [
            dateLabel,
            `${MONTHS[month - 1]} ${day}`,
            `${MONTHS[month - 1].slice(0, 3)} ${day}`,
            monthLabel,
            date
          ]
        : []
      const plugins = pluginsNamed(text)
      return {
        version: note.version,
        id: `v${note.version.replace(/[^A-Za-z0-9]+/g, '-')}`,
        date,
        dateLabel,
        monthLabel,
        ...parsed,
        plugins,
        // Its plugin tags' names too, so clicking a tag (which searches its name) finds it.
        searchText: [note.version, ...dateWords, text, ...plugins.map(plugin => plugin.name)]
          .join(' ')
          .toLowerCase()
      }
    })
}

/** A docs/releases file name: v<version>.md. scripts/changelog-sources.mjs uses the same pattern. */
export const releaseNotesFile = /^v\d+\.\d+\.\d+.*\.md$/

/**
 * What a search shows. A query found as a whole phrase (so `Oct 5`, `beta.1`, or `Clipboard History`
 * means that date, version, or plugin) shows only the releases with that phrase; otherwise every
 * word must appear somewhere in a release, so a partly typed word still finds it. `terms` are what
 * to highlight.
 */
export function searchReleases<T extends Pick<Release, 'searchText'>>(
  releases: readonly T[],
  query: string
): { shown: T[]; terms: string[] } {
  const phrase = query.trim().toLowerCase().replace(/\s+/g, ' ')
  if (!phrase) return { shown: [...releases], terms: [] }
  const whole = new RegExp(`(?:^|[^a-z0-9])${escapeRegExp(phrase)}(?:$|[^a-z0-9])`)
  const byPhrase = releases.filter(release => whole.test(release.searchText))
  if (byPhrase.length) return { shown: byPhrase, terms: [phrase] }
  const words = phrase.split(' ')
  return {
    shown: releases.filter(release => words.every(word => release.searchText.includes(word))),
    terms: words
  }
}
