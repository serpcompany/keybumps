# SERP licensing service

This Cloudflare Worker with D1 issues License Keys and signs Leases for SERP macOS apps. Decisions and terms are in [`docs/adr/0001-licensing.md`](../../docs/adr/0001-licensing.md) and [`CONTEXT.md`](../../CONTEXT.md). It lives here until a second app needs it.

## Develop

```sh
npm ci
npm run typecheck
npm test          # Vitest inside the Workers runtime, with a throwaway signing key
```

## API

All endpoints take a JSON body and return JSON. Errors look like `{"error": "<code>"}`.

| Endpoint | Body | Success |
| --- | --- | --- |
| `POST /v1/activate` | `product`, `key`, `deviceHash` (64 hex chars) | `{lease}` |
| `POST /v1/refresh` | same | `{lease}` |
| `POST /v1/deactivate` | same | `{ok: true}` |
| `POST /admin/licenses` | `product`, optional `validUntil`, `updatesUntil` (Unix seconds), `maxActivations` | `201 {licenseId, key}` |
| `POST /admin/licenses/lookup` | `product`, `key` | status, Entitlement, activation count |
| `POST /admin/licenses/revoke` | `product`, `key` | `{ok: true}` |
| `POST /admin/licenses/reset-activations` | `product`, `key` | `{ok: true}` |

Admin routes require `Authorization: Bearer $ADMIN_TOKEN`.

The app relies on these error codes, so they must stay stable:

| Code | Status |
| --- | --- |
| `bad_request` | 400 |
| `invalid_key` | 404 |
| `revoked` | 403 |
| `expired` | 403 |
| `not_activated` | 403 |
| `activation_limit` | 409 |
| `rate_limited` | 429 |

`refresh` never takes a new slot. A Mac whose activation was reset or deactivated gets `not_activated` and must activate again.

## Lease format

A Lease is `base64url(JSON payload)` + `.` + `base64url(Ed25519 signature over the first segment)`. The payload has these fields:

```
v, kid, licenseId, product, deviceHash, validUntil, updatesUntil, issuedAt, refreshAfter, expiresAt
```

All times are Unix seconds. `validUntil` and `updatesUntil` may be `null`. Timing rules are in `src/policy.ts`.

## Secrets

Nothing here is configured or deployed yet. Deploying requires owner authorization.

| Secret | Value |
| --- | --- |
| `LEASE_SIGNING_KEY` | `{"kid", "jwk"}`. Create it with `npm run generate-signing-key -- <kid>`, which prints the public key for the app's Info.plist. |
| `ADMIN_TOKEN` | A long random string. |

Never log keys, device hashes, emails, or request bodies. Observability is off in `wrangler.toml`.
