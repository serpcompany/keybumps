export const LATEST_RELEASE_URL = 'https://updates.keybumps.app/latest.json';

export type LatestRelease = {
  version: string;
  build: number;
  dmgURL: string;
  sha256: string;
};

/** Shown until latest.json is published, or whenever it can't be read or validated. */
export const FALLBACK_RELEASE: LatestRelease = {
  version: '0.0.3-beta.3',
  build: 4007,
  dmgURL:
    'https://updates.keybumps.app/releases/4007/Keybumps-0.0.3-beta.3.dmg',
  sha256: 'fab25c2e3bbc0c31c413797e87e86d631d41d4419b54265c70f93e87ebe16dd5',
};

/** Accepts only a well-formed pointer whose DMG lives on the release origin. */
export function parseLatestRelease(value: unknown): LatestRelease | null {
  if (typeof value !== 'object' || value === null) return null;
  const { version, build, dmgURL, sha256 } = value as Record<string, unknown>;
  if (
    typeof version !== 'string' ||
    !/^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$/.test(version)
  )
    return null;
  if (typeof build !== 'number' || !Number.isInteger(build) || build <= 0)
    return null;
  if (typeof sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(sha256)) return null;
  if (typeof dmgURL !== 'string') return null;
  let url: URL;
  try {
    url = new URL(dmgURL);
  } catch {
    return null;
  }
  if (url.protocol !== 'https:' || url.hostname !== 'updates.keybumps.app')
    return null;
  if (url.username || url.password || url.search || url.hash) return null;
  if (!url.pathname.endsWith(`/Keybumps-${version}.dmg`)) return null;
  return { version, build, dmgURL, sha256 };
}

/** Reads the pointer written by the Keybumps release tooling; never throws. */
export async function getLatestRelease(
  fetcher: typeof fetch = fetch,
): Promise<LatestRelease> {
  try {
    const response = await fetcher(LATEST_RELEASE_URL, {
      next: { revalidate: 300 },
    } as RequestInit);
    if (!response.ok) return FALLBACK_RELEASE;
    return parseLatestRelease(await response.json()) ?? FALLBACK_RELEASE;
  } catch {
    return FALLBACK_RELEASE;
  }
}
