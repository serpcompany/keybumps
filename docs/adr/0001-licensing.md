# 0001: Licensing, payments, and entitlement

Status: Accepted (2026-09-28). Tracked by #118.

## Context

Keybumps ships as a Developer ID-signed direct download updated through Sparkle, not through the Mac App Store. To sell it, we need checkout, license delivery, activation, and a way to revoke refunded purchases. The service must be reusable by future SERP macOS apps. It must also let us swap payment providers (Polar now, Stripe or our Lago stack later) and test different pricing strategies without shipping new app builds. User content never leaves the Mac.

## Decisions

1. **License keys, no accounts.** Customers buy on the website and receive a License Key. The app has no sign-in. A customer who loses a key recovers it through the provider's hosted customer portal or the receipt email. We will not use BetterAuth or any other account system unless a later ADR adds accounts.
2. **Polar is the first payment provider, as merchant of record.** Polar collects and remits global VAT and sales tax. Selling through Stripe directly would make us the merchant of record, responsible for registering and filing tax in every jurisdiction.
3. **One SERP licensing service owns keys, licenses, and leases.** It is a Cloudflare Worker with D1, in its own repository, serving every SERP app keyed by product.
   - Apps talk only to this service, never to Polar, Stripe, or Lago.
   - Providers sit behind a server-side `ProviderAdapter` that verifies webhooks and emits normalized events: order paid, order refunded, dispute opened, subscription active/renewed/canceled/revoked.
   - Domain tables store only `provider` and `provider_ref`.
   - We generate our own keys instead of using a provider's license keys, so changing providers never invalidates a customer's key.
4. **Entitlements do not depend on pricing.** Each checkout variant is an Offer, and each Offer maps to an Entitlement on the License. The app enforces only three fields:
   - `validUntil`: absent means perpetual, and subscriptions and fixed terms set it.
   - `updatesUntil`: a build released after this date is not entitled, so customers keep the versions they paid for.
   - `maxActivations`: the default is 3 Macs.

   One-time, one-time with an update window, and subscription offers can therefore run side by side, and pricing experiments need no app release.
5. **Signed leases, verified offline.** Activation exchanges a License Key and a device hash for a Lease: a compact payload signed by the service with Ed25519.
   - The app verifies the Lease with CryptoKit against a public key embedded in Info.plist. The private key lives only in Worker secrets, like Sparkle's EdDSA key.
   - The app stores the Lease and key in the Keychain.
   - The device hash is SHA-256 of the hardware UUID with a per-product salt. Only the hash leaves the Mac.
6. **Revocation happens through lease expiry, not a remote kill switch.**
   - A Lease carries `refreshAfter` (about 7 days) and `expiresAt` (about 45 days). The app refreshes silently whenever it is online after `refreshAfter`.
   - Refunds, disputes, and ended subscriptions mark the License revoked, and the next refresh returns `revoked`.
   - An offline Mac keeps working until `expiresAt` and sees a warning during its final week.
   - A network or server error never changes the current state.
   - We don't use obfuscation, anti-debugging, or DRM. The goal is to deter casual sharing without ever locking out a paying customer.
7. **Locked until activated. There is no trial.** Without an entitled Lease, capabilities do not start. Only onboarding, the License settings page, and Quit are available.
8. **Privacy.** Licensing requests carry only product, License Key, device hash, app version, and OS version. Neither the app nor the service logs keys, device hashes, or anything else about user content.

## Consequences

- Licensing is an app-shell seam (`LicenseControlling`), modeled on `UpdateControlling`. Capability modules never see it except through whether the capability is allowed to start.
- The development license adapter placeholder and the "purchasing is not configured" copy are retired.
- Creating the service repository, the Polar account, production signing keys, and live checkout all require fresh owner authorization.
- Adding Stripe or Lago later means a new `ProviderAdapter` implementation and Offer rows. It needs no app change and no key migration.
