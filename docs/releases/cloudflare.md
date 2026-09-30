# Cloudflare resources

Keybumps's public web presence runs on the **SERP** Cloudflare account (`cec5f04e1d18bcc65f2be0aefb04f059`). Inventory captured 2026-09-28, updated 2026-09-30 after the website moved into this repository. Update this file whenever a resource changes.

| Resource | Purpose | Owned and configured by |
| --- | --- | --- |
| Zone `keybumps.app` (`e641400d1648da94e95380533b25d227`) | DNS, TLS, and Email Routing for `keybumps.app`, `www.keybumps.app`, `staging.keybumps.app`, and `updates.keybumps.app` (all proxied through Cloudflare) | Cloudflare dashboard |
| Worker `keybumps-web-production` | Serves `keybumps.app` and `www.keybumps.app` (custom domains). `/download/` redirects to the current DMG. | This repository: `apps/web/wrangler.jsonc`, deployed only by `.github/workflows/web-deploy.yml` |
| Worker `keybumps-web-staging` | Serves `staging.keybumps.app` (custom domain, not indexed) | This repository: `apps/web/wrangler.jsonc`, deployed only by `.github/workflows/web-deploy.yml` |
| R2 bucket `keybumps-updates` (APAC, Standard storage) | Release origin behind the `updates.keybumps.app` custom domain (TLS 1.2+). Public `r2.dev` access is disabled. No CORS rules. Lifecycle: abort incomplete multipart uploads after 7 days. | This repository: `apps/macos/scripts/publish-release.sh` |

## Release origin layout (`updates.keybumps.app`)

| Key | Content type | Cache-Control | Notes |
| --- | --- | --- | --- |
| `releases/<build>/Keybumps-<version>.zip` (+ `.sha256`) | `application/zip` | `public, max-age=31536000, immutable` | Sparkle update archive |
| `releases/<build>/Keybumps-<version>.dmg` (+ `.sha256`) | `application/x-apple-diskimage` | immutable | Customer download |
| `releases/<build>/Keybumps-<version>.md` | `text/markdown; charset=utf-8` | immutable | Linked release notes |
| `appcast.xml` | `application/xml; charset=utf-8` | `public, max-age=60, must-revalidate` | Production Sparkle feed (pointer) |
| `staging/appcast.xml` | same as above | same | Staging Sparkle feed (pointer) |
| `latest.json` | `application/json; charset=utf-8` | `public, max-age=60, must-revalidate` | Latest-release pointer for the website's Download buttons and `/download/` redirect (`version`, `build`, `dmgURL`, `sha256`) |

Production and staging feeds share the same immutable `releases/<build>/` assets. Assets are never overwritten; pointers are published last.

Found at inventory time: releases 4006 (`0.0.3-beta.2`) and 4007 (`0.0.3-beta.3`); the production feed advertised 4007 and staging advertised 4006. `latest.json` was not yet published, and the 4007 ZIP had been uploaded as `application/octet-stream` before these conventions existed.

## Access

- Publishing uses `wrangler r2 object put` with `CLOUDFLARE_API_TOKEN` set to an API token scoped to **Workers R2 Storage: Edit** on the `keybumps-updates` bucket only. The same token reads objects back (`wrangler r2 object get`): every Release Keybumps run reads the live `appcast.xml` for the build number, and publishing verifies each upload byte for byte. Reads go to R2 directly because Cloudflare Bot Fight Mode returns 403 to GitHub-hosted runners on `updates.keybumps.app`; check the public host with `apps/macos/scripts/verify-update-publication.sh` from a normal network. It lives in the `CLOUDFLARE_R2_TOKEN` repository secret for the Release Keybumps workflow; anywhere else, provide it through the environment. Never put it in the repository, shell history, or chat.
- Publishing, DNS, and bucket changes require fresh owner authorization (see `AGENTS.md`).
