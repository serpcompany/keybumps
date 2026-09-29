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
| `POST /v1/resend-key` | `email` | Always `202 {ok: true}`. Emails active keys to that address at most once per 10 minutes. The website calls it server-side. |
| `POST /admin/licenses` | `product`, optional `validUntil`, `updatesUntil` (Unix seconds), `maxActivations` | `201 {licenseId, key}` |
| `POST /webhooks/polar` | Polar webhook (Standard Webhooks signature) | `{ok: true}`; `422 unknown_offer` makes Polar retry |
| `POST /admin/offers` | `id`, `product`, `provider`, `providerRef` (provider product id), `kind` (`perpetual`, `update_window`, `subscription`), optional `updatesDays`, `maxActivations`, `active` | `{ok: true}` (upsert) |
| `POST /admin/licenses/by-email` | `email` | `{licenses}` |
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

## Offers and Polar

A paid order becomes a License through an Offer. The checkout link's `offer` metadata picks the Offer. Without it, the service uses the first active Offer for the Polar product. Register each Offer with `POST /admin/offers` before its checkout link goes live. Until then, Polar gets `422` and retries.

## Key email

A paid order emails its License Key through Cloudflare Email Service (the `EMAIL` `send_email` binding, restricted to sending from `support@keybumps.app`, which also receives replies (SERP transactional-email standard); `keybumps.app` must be onboarded under Email Service > Email Sending, which needs the Workers Paid plan). The sender is the `EMAIL_FROM` var. If sending fails, the order is still acknowledged. A cron (every 15 minutes) retries keys whose `licenses.key_emailed_at` is still unset, for up to 7 days. A crash between sending and recording can, rarely, send the same key twice. `/v1/resend-key` does its lookup and sending after responding, so response time never reveals whether an address bought.

## Environments

`--env staging` is `keybumps-licensing-staging`, backed by the Polar sandbox. Its admin token and public key live in the git-ignored `staging.secrets.json`. Production isn't configured.

## Secrets

Each environment sets these with `wrangler secret put --env <env>`. Deploying production requires owner authorization.

| Secret | Value |
| --- | --- |
| `LEASE_SIGNING_KEY` | `{"kid", "jwk"}`. Create it with `npm run generate-signing-key -- <kid>`, which prints the public key for the app's Info.plist. |
| `ADMIN_TOKEN` | A long random string. |
| `POLAR_WEBHOOK_SECRET` | The Polar endpoint's secret (`whsec_...`). Webhooks are rejected while it's unset. |

Rate limiting is keyed per License Key through the optional `KEY_LIMITER` binding. It isn't configured yet and is added at deploy time. Guessing keys isn't practical against 80-bit keys.

Never log keys, device hashes, emails, or request bodies. Observability is off in `wrangler.toml`.
