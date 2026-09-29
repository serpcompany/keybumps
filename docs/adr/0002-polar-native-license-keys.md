# 0002: Polar-native license keys

Status: Accepted (2026-09-29). Supersedes parts of [0001](0001-licensing.md). Tracked by #118 and #130.

## Context

ADR 0001 had the service own keys and signed Leases so the payment provider could be swapped without migrating keys. That needed a service, a database, key email, and their operations. The owner chose the faster, simpler path: sell Keybumps with Polar's built-in license keys. The provider can still be changed later by migrating keys (see Consequences).

## Decisions

1. **Polar issues and manages License Keys.** The live product has a License Key benefit:
   - prefix `KEYBUMPS`
   - an activation limit of 1 Mac
   - no expiry for the lifetime offer

   The benefit also allows customers to deactivate from the portal.

   Polar delivers the key in its receipt email and customer portal. The portal also covers "I lost my key" and freeing a Mac.
   - **Refunds:** Polar revokes the key only when its benefit is revoked. For one-time purchases, refunding does not do that by default, so every refund must be issued with **Revoke benefits** turned on, in the dashboard or with `revoke_benefits` in the API.
   - **Disputes:** Polar settles disputes as merchant of record. If one is lost, revoke the customer's benefit by hand.
2. **The app talks to Polar's public license-key API.** It uses the customer-portal endpoints (`/v1/customer-portal/license-keys/activate`, `/validate`, `/deactivate`), which take the key and the organization id and need no secret in the app. Activation sends a label built from the device hash, never a Mac name or other personal data.
3. **One app-side seam.** `LicenseControlling` talks to a `LicenseProviding` protocol. Polar is its first and only implementation. Changing providers means adding another implementation and shipping an app update.
4. **Offline use without a Lease.** The app stores its key, its Polar activation id (which validation and deactivation require), and its last successful validation in the Keychain:
   - It revalidates once every 24 hours when online (at launch, on wake, or on an hourly timer, whenever a check is due), so a revoked or refunded key locks within about a day. **Check Again** on the License page checks immediately. While Locked, a check runs at every launch, wake, and timer tick, so a restored license unlocks on its own. This follows the SERP native-app licensing and updates standard.
   - It keeps working for 45 days after the last successful validation.
   - A network or server error never changes the current state.
   - A `revoked` or `disabled` answer locks the app at the next check.

   Without a signature, a determined user can fake the cached result. That's accepted, as in 0001's no-DRM posture.
5. **Still in force from 0001:** license keys only with no accounts; Locked until activated with no trial; the app-shell seam, never read by capability modules; and the privacy rules (nothing licensing-related is logged, and requests carry only what the API needs).

## Superseded from 0001

- The SERP licensing service, which owned keys, Offers, Ed25519 Leases, and the provider adapter.
- Key email and the resend form. Polar's receipt and portal replace them.
- `updatesUntil` and gating Sparkle on it. The lifetime offer includes all updates.
- The trusted-time high-water mark, since there's no signed Lease to protect.

## Consequences

- The owned licensing service was decommissioned (Workers, D1 databases, and the Polar sandbox webhook deleted) and its code removed in #134. It's recoverable from git history (last present at `df14c44`, under `services/licensing/`) if provider independence is ever needed.
- **Moving off Polar later:**
  1. Export keys, owners, and activation counts from Polar's API.
  2. Import them into an owned service.
  3. Ship an app update with a new `LicenseProviding` implementation.
  4. Keep Polar validating until old versions age out.
- The website's `/license` and `/thanks` point to Polar's receipt and customer portal.
