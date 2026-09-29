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
| `POST /v1/activate` | `product`, `key`, `deviceHash` (64 hex chars, any case; stored lowercase) | `{lease}` |
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

`expired` means a subscription or fixed term ended more than 7 days ago. `revoked` means a refund, dispute, or admin action. `refresh` never takes a new slot. A Mac whose activation was reset or deactivated gets `not_activated` and must activate again.

## Lease format

A Lease is `base64url(JSON payload)` + `.` + `base64url(Ed25519 signature over the first segment)`. The payload has these fields:

```
v, kid, licenseId, product, deviceHash, validUntil, updatesUntil, issuedAt, refreshAfter, expiresAt
```

This is the contract the app's verifier implements. All times are Unix seconds. `v` is the format version (currently `1`). `validUntil` and `updatesUntil` are always present and may be `null`, meaning no limit. Timing rules are in `src/policy.ts`.

## Secrets

Nothing here is configured or deployed yet. Deploying requires owner authorization.

| Secret | Value |
| --- | --- |
| `LEASE_SIGNING_KEY` | `{"kid", "jwk"}`. Create it with `npm run generate-signing-key -- <kid>`, which prints the public key for the app's Info.plist. |
| `ADMIN_TOKEN` | A long random string. |

Rate limiting is keyed per License Key through the optional `KEY_LIMITER` binding. It isn't configured yet and is added at deploy time. Guessing keys isn't practical against 80-bit keys.

Never log keys, device hashes, emails, or request bodies. Observability is off in `wrangler.toml`.
