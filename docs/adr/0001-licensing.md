# 0001: Licensing, payments, and entitlement

Status: Accepted (2026-09-28). Tracked by #118.

## Context

Keybumps ships as a Developer ID-signed direct download updated through Sparkle, not through the Mac App Store. To sell it we need four things: checkout, license delivery, activation, and a way to revoke refunded purchases. The service must be reusable by future SERP macOS apps. It must let us swap payment providers: Polar now, and later Stripe or our Lago billing stack with a gateway behind it. It must also let us test pricing strategies without shipping app builds. User content never leaves the Mac.

## Decisions

1. **License keys, no accounts.**
   - Customers buy on the website and receive a License Key. The app has no sign-in.
   - The licensing service emails the key when the purchase is paid, from `support@keybumps.app` through Cloudflare Email Service. Following the SERP transactional-email standard, that one address both sends and receives replies.
   - A "resend my key" form on the website emails every key on file to the purchase address, and only to that address.
   - We will not use BetterAuth or any other account system unless a later ADR adds accounts.
2. **Polar is the first payment provider, as merchant of record.**
   - Polar collects and remits global VAT and sales tax.
   - Selling through Stripe directly would make us the merchant of record, responsible for registering and filing wherever we pass tax thresholds. EU VAT on digital goods applies from the first sale.
3. **One SERP licensing service owns keys, licenses, and leases.** It is a Cloudflare Worker with D1, serving every SERP app keyed by product. It starts in this repository under `services/licensing/`, with its own toolchain and CI job kept apart from the Swift app. It moves to a shared repository when a second app needs it. Keys and Licenses live in D1, so moving it changes nothing for customers.
   - Apps talk only to this service, never to Polar, Stripe, or Lago.
   - Providers sit behind a server-side `ProviderAdapter`. It verifies webhooks and emits normalized events: order paid, order refunded, dispute opened, and subscription active/renewed/canceled/ended. Providers that settle disputes themselves and send no dispute event (Polar, as merchant of record) report the outcome as a refund.
   - Domain tables store only `provider` and `provider_ref`.
   - We mint our own keys instead of using a provider's license keys, so changing providers never invalidates a customer's key.
4. **Entitlements do not depend on pricing.** Each checkout variant is an Offer, and each Offer maps to an Entitlement on the License:
   - `validUntil`: absent means perpetual. Subscriptions set it to the end of the paid period.
   - `updatesUntil`: builds released after this date are not entitled.
   - `maxActivations`: the default is 3 Macs.

   The app checks `validUntil` and `updatesUntil`. The service enforces `maxActivations` during Activation. One-time, one-time with an update window, and subscription offers can therefore run side by side, and pricing experiments need no app release.
5. **The updater respects `updatesUntil`.**
   - Each release embeds its release date in Info.plist (`KBBuildReleaseDate`), set by the release script.
   - The release script also publishes that same date as a custom element on the build's appcast item. Sparkle's `pubDate` is for display only.
   - The licensing seam filters appcast items in Sparkle's `bestValidUpdate` delegate. Items released after `updatesUntil` are never offered or installed, and the installed, entitled build keeps working.
   - The License settings page, not Sparkle, shows that a newer version needs an upgrade.
   - A newer build installed by hand is Locked, with an "outside your update window" message and a link to the last covered version.
6. **Signed leases, verified offline.**
   - Activation exchanges a License Key and a device hash for a Lease. The Lease is a compact payload the service signs with Ed25519: `{v, kid, licenseId, product, deviceHash, validUntil, updatesUntil, issuedAt, refreshAfter, expiresAt}`, where `validUntil` and `updatesUntil` are `null` when unlimited. `services/licensing/README.md` is the exact wire contract.
   - The app verifies the signature with CryptoKit and rejects any Lease whose `product` or `deviceHash` differs from its own.
   - Info.plist embeds a small set of public keys indexed by `kid`, so the signing key can be rotated by shipping the new public key before signing with it. Private keys live only in Worker secrets, like Sparkle's EdDSA key.
   - A leaked key stays trusted by builds already installed until they update. This is accepted as a risk for software without DRM: the response is to rotate the key and drop the old `kid` in the next release.
   - The app stores the Lease and key in the Keychain.
   - The device hash is SHA-256 of the hardware UUID and a per-product salt embedded in the app. Only the hash leaves the Mac.
7. **Revocation happens through lease expiry, not a remote kill switch.**
   - A Lease carries `refreshAfter` (about 7 days) and `expiresAt` (about 45 days).
   - The app refreshes silently whenever it's online after `refreshAfter`. The next refresh returns `revoked` after a refund or dispute, and `expired` once a subscription's paid period and grace have ended. A subscription that is canceled but still paid for stays valid until `validUntil`.
   - A Mac that stays offline keeps working until `expiresAt`, and sees a warning during the final week. Past that point, one successful refresh is required.
   - A subscription Lease is refreshed as soon as `validUntil` passes, and stays usable for a 7-day grace period, retrying about daily, so a renewal that hasn't reached the app yet doesn't lock the Mac. For subscriptions, the service caps `expiresAt` at `validUntil` plus that grace, so an offline subscriber must reconnect after each paid period.
   - These are the only cases where a paying customer must reconnect.
   - A network or server error never changes the current state.
   - The app keeps a Keychain high-water mark of trusted time. It starts at a Lease's server-issued `issuedAt`.
   - While Keybumps runs, the mark advances by elapsed `mach_continuous_time` (which counts sleep), and it is saved periodically. The mark keeps accumulating across reboots.
   - Every successful refresh resets the mark to the server's time. A local clock earlier than the mark is treated as the mark.
   - Setting the clock forward cannot poison the mark, because the wall clock never moves it.
   - Rolling the clock back can therefore gain at most the time the Mac spent shut down or with Keybumps not running. A Lease still expires within about 45 days of Keybumps actually running. We accept this remaining gap in the no-DRM posture.
   - We don't use obfuscation, anti-debugging, or DRM. The goal is to deter casual sharing without locking out paying customers.
8. **Activation slots can be recovered.**
   - Deactivating in the app frees its slot.
   - For a lost Mac or a replaced logic board, the key-resend email includes a self-serve "reset activations" link, limited to once per 30 days. Support can also reset.
9. **Locked until activated. There is no trial.** Without an entitled Lease, capabilities do not start. Only onboarding, the License settings page, and Quit are available.
10. **Privacy.**
    - Licensing requests carry only product, License Key, device hash, app version, and OS version.
    - The service stores the purchase email, which comes from the provider, only to deliver and resend keys.
    - The resend form always replies with the same message, so it never reveals whether an address has bought.
    - The service does not store client IP addresses. Rate limiting uses short-lived counters.
    - Workers request logging stays off for licensing routes.
    - Neither the app nor the service logs keys or device hashes.

## Consequences

- Current beta testers are Locked by the first licensed build unless they hold a License. Before that build ships, the owner decides whether to give testers complimentary Licenses (issued through the service's admin surface) and announces the change in its release notes.

- Licensing is an app-shell seam (`LicenseControlling`), modeled on `UpdateControlling`. Capability modules see it only in whether they may start.
- The Settings account page's "Local Preview" license group and the onboarding sentence saying purchasing is not part of this preview (`SettingsRootView.swift`) are replaced by the License page and an activation step.
- The development license adapter placeholder is retired.
- Deploying the service, the Polar account, production signing keys, and live checkout all require fresh owner authorization.
- Adding Stripe or Lago later means a new `ProviderAdapter` and new Offer rows. No app change and no key migration.
