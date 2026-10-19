# Cloudflare resources

Keybumps's public web presence runs on the **SERP** Cloudflare account (`cec5f04e1d18bcc65f2be0aefb04f059`). Inventory captured 2026-09-28, updated 2026-09-30 after the website moved into this repository. Update this file whenever a resource changes.

| Resource | Purpose | Owned and configured by |
| --- | --- | --- |
| Zone `keybumps.app` (`e641400d1648da94e95380533b25d227`) | DNS, TLS, and Email Routing for `keybumps.app`, `www.keybumps.app`, `staging.keybumps.app`, and `updates.keybumps.app` (all proxied through Cloudflare) | Cloudflare dashboard |
| Worker `keybumps-web-production` | Serves `keybumps.app` and `www.keybumps.app` (custom domains). `/download/` redirects to the current DMG. | This repository: `apps/web/wrangler.jsonc`, deployed only by `.github/workflows/web-deploy.yml` |
| Worker `keybumps-web-staging` | Serves `staging.keybumps.app` (custom domain, not indexed) | This repository: `apps/web/wrangler.jsonc`, deployed only by `.github/workflows/web-deploy.yml` |
| R2 bucket `keybumps-updates` (APAC, Standard storage) | Release origin behind the `updates.keybumps.app` custom domain (TLS 1.2+). Public `r2.dev` access is disabled. No CORS rules. Lifecycle: abort incomplete multipart uploads after 7 days. | This repository: `apps/macos/scripts/publish-release.sh` and `publish-release-index.sh` |

## Release origin layout (`updates.keybumps.app`)

| Key | Content type | Cache-Control | Notes |
| --- | --- | --- | --- |
| `releases/<build>/Keybumps-<version>.zip` | `application/zip` | `public, max-age=31536000, immutable` | Sparkle update archive |
| `releases/<build>/Keybumps-<version>.dmg` | `application/x-apple-diskimage` | immutable | Customer download |
| `releases/<build>/Keybumps-<version>.{zip,dmg}.sha256` | `text/plain; charset=utf-8` | immutable | Checksum sidecars |
| `releases/<build>/Keybumps-<version>.md` | `text/markdown; charset=utf-8` | immutable | Linked release notes |
| `appcast.xml` | `application/xml; charset=utf-8` | `public, max-age=60, must-revalidate` | Production Sparkle feed (pointer) |
| `staging/appcast.xml` | same as above | same | Staging Sparkle feed (pointer) |
| `latest.json` | `application/json; charset=utf-8` | `public, max-age=60, must-revalidate` | Latest-release pointer for the website's Download buttons and `/download/` redirect (`version`, `build`, `dmgURL`, `sha256`) |
| `releases.json` | same as above | same | Release index: every production release's DMG (see below) |

Production and staging feeds share the same immutable `releases/<build>/` assets. Assets are never overwritten; pointers are published last.

### Release index (`releases.json`)

A JSON array with one entry per production release, newest (highest build) first:

```json
[
  {
    "version": "0.0.3-beta.28",
    "build": 4033,
    "url": "https://updates.keybumps.app/releases/4033/Keybumps-0.0.3-beta.28.dmg",
    "releasedAt": "2026-10-19T15:21:01Z"
  }
]
```

- `url` is always that release's immutable DMG, `releases/<build>/Keybumps-<version>.dmg`.
- `releasedAt` is the UTC release date the build's appcast item carries (`<keybumps:releaseDate>`, ADR 0011). Releases before beta.29 carry none, so their entries hold the time their DMG was uploaded (its `Last-Modified`), within minutes of the build. The app counts those builds as covered by every update year.
- Each version appears once, with its production build. A version published again under a higher build replaces its entry.
- Who writes it: `apps/macos/scripts/publish-release.sh` adds each production release after `appcast.xml` and `latest.json`, through `publish-release-index.sh`, which only adds to or replaces entries in the live list, and never drops a version. Nothing else writes it. Before staging publishes, the Release Keybumps `build` job checks the release merges into the live list (`publish-release.sh … production --check-index`, which reads `releases.json` and uploads nothing), so a list that would stop production shows before approval.
- Who reads it: the website's `/changelog/` build, to link each release's DMG from beta.13 on (#565). The appcast lists only the newest release, so this is the only record of which build holds each version. A GitHub-hosted runner can't fetch it from `updates.keybumps.app` (Bot Fight Mode, see Access below), so Web deploy (`.github/workflows/web-deploy.yml`) reads it from R2 before building, and the build stops if the list can't be read or lacks a version that the site's committed copy, `apps/web/scripts/release-index.fixture.json`, lists.
- The one-time backfill of beta.2 to beta.28 is `apps/macos/scripts/release-index-backfill.json`, uploaded (owner-authorized) with `apps/macos/scripts/publish-release-index.sh apps/macos/scripts/release-index-backfill.json --publish`. It merges with whatever is live, so it can run before or after the next release, but not while one is publishing: each upload reads the live list, adds to it, and writes it back. No beta.1 DMG was ever published, and beta.6's first build, 4010, was replaced in production by 4011 five minutes later, so the backfill lists 4011.

Found at inventory time: releases 4006 (`0.0.3-beta.2`) and 4007 (`0.0.3-beta.3`); the production feed advertised 4007 and staging advertised 4006. `latest.json` was not yet published, and the 4007 ZIP had been uploaded as `application/octet-stream` before these conventions existed.

## Access

- Publishing uses `wrangler r2 object put` with `CLOUDFLARE_API_TOKEN` set to an API token scoped to **Workers R2 Storage: Edit** on the `keybumps-updates` bucket only. The same token reads objects back (`wrangler r2 object get`): every Release Keybumps run reads the live `appcast.xml` for the build number, a publishing run reads the live `releases.json` before staging (to check the release merges into it) and again in production (to add it), and publishing verifies each upload byte for byte. Reads go to R2 directly because Cloudflare Bot Fight Mode returns 403 to GitHub-hosted runners on `updates.keybumps.app`; check the public host with `apps/macos/scripts/verify-update-publication.sh` from a normal network. It lives in the `CLOUDFLARE_R2_TOKEN` repository secret, used by the Release Keybumps workflow and by Web deploy's **Read the release index from R2** step, which only reads `releases.json`, with `curl`, before any dependencies install; anywhere else, provide it through the environment. Never put it in the repository, shell history, or chat.
- Publishing, DNS, and bucket changes require fresh owner authorization (see `AGENTS.md`).
