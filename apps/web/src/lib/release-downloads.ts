import { compareVersions } from './changelog'
import type { LatestRelease } from './latest-release'

/**
 * A release the release index names, as scripts/release-index.mjs checked and copied it into
 * src/generated/release-index.json when the site was built: its version, build, and immutable DMG.
 */
export type IndexedRelease = { version: string; build: number; url: string }

/**
 * The oldest release /changelog/ links a download for. It is the first build notarized again
 * (beta.4 to beta.12 weren't, so a fresh download is blocked on first launch), and in-app licensing
 * arrived earlier, in beta.7, so no earlier build runs without a license. Every update year runs
 * through at least 2027-10-19 (ADR 0011), so a lapsed license never needs anything older.
 */
export const OLDEST_DOWNLOAD = '0.0.3-beta.13'

/**
 * Each release's download on /changelog/ (#565), by version, for `versions` newest first. A lapsed
 * license's update year covers only earlier releases (ADR 0011), and the app's Settings › Account
 * sends people here for them (Earlier Versions…), so each release from OLDEST_DOWNLOAD on links its
 * own DMG from the index baked in at build time. The newest links the current download, from
 * latest.json on request as every Download button does (`getCurrentRelease`), when that names the
 * same version. Otherwise, as while latest.json is unreadable and the site falls back to an older
 * build, it keeps its own DMG. A version the index doesn't list gets no link rather than a guessed
 * URL.
 */
export function releaseDownloads(
  versions: readonly string[],
  index: readonly IndexedRelease[],
  current: LatestRelease
): Record<string, string> {
  const dmg = new Map(index.map(release => [release.version, release.url]))
  const downloads: Record<string, string> = {}
  versions.forEach((version, position) => {
    if (compareVersions(version, OLDEST_DOWNLOAD) < 0) return
    const url = position === 0 && current.version === version ? current.dmgURL : dmg.get(version)
    if (url) downloads[version] = url
  })
  return downloads
}
