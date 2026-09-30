import { downloadRedirect, getLatestRelease } from '@/lib/latest-release'

// /download/ (and /download, which takes the site's one trailing-slash 308 first) is an external
// contract: old links, READMEs, emails, and receipts point at it. It has no page; each request
// gets a temporary redirect to the current DMG from latest.json, so it always gives the latest
// build. Always run on request: a prerendered redirect would keep the build-time DMG.
export const dynamic = 'force-dynamic'

export async function GET() {
  return downloadRedirect(await getLatestRelease())
}
