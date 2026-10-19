# 0011: A license includes a year of updates, counted from the key's purchase date

Status: Accepted (2026-10-19). Tracked by #548. Supersedes parts of [0002](0002-polar-native-license-keys.md); see "Superseded".

## Context

On 2026-10-19 the owner changed how Keybumps is sold (#547, #550). A $97 license includes the updates released in the year after purchase, new plugins among them; a license bought before that day includes the updates released through 2027-10-19. Another year of updates costs $49, sold as a yearly auto-renewal that's on by default. Someone who doesn't renew keeps the last version released in their year, and Keybumps keeps working.

ADR 0001 §5 designed this window as `updatesUntil`, and ADR 0002 dropped it with the owned licensing service. Today Polar issues the keys, the app talks only to Polar's public customer-portal API, and `LicensePolicy.state` locks the app once a key's `expires_at` passes.

What Polar does (its server code and API spec, read 2026-10-19; notes in #548):

- **An expired key is refused like a refunded one.** Validate answers 404 for an expired, revoked, disabled, or unknown key alike; only the `detail` text differs. Activate answers 403 for an expired key, so a lapsed customer couldn't set up a new Mac. Neither returns the key's fields once it has expired.
- **Polar rewrites expiries.** Editing a License Key benefit's expiry, activation, or usage settings resets every one-time key's `expires_at` to the edit time plus the benefit's expiry.
- **Validate and activate return the key's `created_at`** (when the purchase granted it; rotating the key keeps it) **and the customer, metadata included.** An organization token with `customers:write` can set that metadata.
- **A subscription with a License Key benefit issues its own, second key**, which never expires and is revoked when the subscription ends. A renewal changes nothing on any key.
- The app sends no `Polar-Version`, so it gets Polar's current API version.

## Decisions

1. **Keys never expire.** The License Key benefit keeps no expiry, and the update year is not Polar's `expires_at`, which would make a lapsed customer look refunded and keep them off a new Mac. Never set an expiry on the benefit.
2. **The update year comes from the key's `created_at`.** Its last day is the UTC day one year after the later of `created_at` and 2026-10-19: a license bought before 2026-10-19 gets updates through 2027-10-19, and one bought on 2026-11-05 through 2027-11-05. A release is covered when its UTC release day is on or before the last day. The app works this out from every validation and activation and keeps `created_at` in its License Check.
3. **A renewal reaches the app as Polar customer metadata.**
   - The renewal is its own $49/year subscription product with no License Key benefit, so it never issues a second key. The license stays the one-time key.
   - When a renewal order is paid or refunded, the site's Polar webhook (`apps/web/src/lib/polar-webhook.ts`) works out the customer's paid-through day again from Polar's records and writes it to the customer's metadata as `keybumps_updates_until` (`YYYY-MM-DD`), merging with the metadata already there. Working it out from scratch makes a retried delivery harmless, and refunding a renewal takes back only its year.
   - A renewal paid before the update year ends adds a year to it; one paid after it ends runs a year from payment. Either way it covers every release up to its new last day, including those released while the license had lapsed.
   - The update year ends on the later of decision 2's day and `keybumps_updates_until`. The app reads it at its next check, within a day, or at once with Check Again on the License page, and checks for updates whenever the last day moves.
   - Metadata belongs to the Polar customer, so one renewal covers every key that customer holds, and a renewal bought under another email doesn't reach the app until support copies the date across.
   - Rejected: an endpoint on the site that the app asks after each check. It would be a public endpoint taking license keys, and the app would talk to a server of ours. It's the fallback if Polar stops returning customer metadata publicly.
4. **Each release carries its release date.** `apps/macos/scripts/build-update-release.sh` stamps the build's UTC time into Info.plist as `KBBuildReleaseDate` and onto the build's appcast item as `<keybumps:releaseDate>`, then re-signs the feed with Sparkle's `sign_update`. `validate-update-release.sh` checks that the two match. A build or appcast item without one (Debug builds, QA candidates, and every release before this one) counts as covered.
5. **The update year ending never locks the app.** The installed version keeps working. The License page shows the update year's last day. Refunds and revocation, and 45 days without a check, still lock as ADR 0002 decided.
6. **A newer release shows, but offers Renew instead of Install.** The licensing seam filters Sparkle's appcast in the `bestValidUpdate` delegate, so an item released after the update year is never downloaded or installed. The app still shows it: the menu bar's red dot, the Check for Updates… item, and Settings › Changelog name the version and offer Renew, which opens keybumps.app/pricing. Check for Updates… after the update year has ended checks quietly and shows the result in Settings › Changelog, because Sparkle's own alert would call the app up to date.
7. **A newer build installed by hand is Locked** until the update year covers it. The License page says it was released after the license's updates ended, with Renew and a link to earlier versions at keybumps.app/changelog. Without this, the site's Download button would bypass the update year.
8. **An unknown update year counts as covered.** That's a License Check stored by an earlier build, or a response without `created_at`. A launch with such a check validates at once to fill it in. While no license is active (deactivated, or never activated on this Mac), the updater keeps filtering by the last update year this Mac learned, so a release the license didn't cover doesn't install and then Lock when the key is activated again.
   - Builds before this one have no filter. A Mac that stayed on one past its update year would install the newest release, which would then Lock. No update year ends before 2027-10-19, and automatic updates bring the filter long before then.

## Superseded

- From 0002 "Superseded from 0001": "`updatesUntil` and gating Sparkle on it. The lifetime offer includes all updates." Each license now has an update year, and the updater respects it (decisions 2, 6).
- From 0002 decision 1: "no expiry for the lifetime offer" still holds for keys; what a license includes changes.
- From 0001 §5: the window comes from Polar, not a signed Lease, and an item released after it still shows (decision 6).

## Consequences

- Polar setup now: none. The benefit already has no expiry.
- Polar setup before renewal goes on sale (owner, #548 items 3–4):
  - The $49/year subscription product, without a License Key benefit.
  - An organization token for the site's Worker with `customers:write`, `orders:read`, `benefits:read`, and `license_keys:read`, and the webhook's subscription to `order.paid` and `order.refunded`.
  - Polar's checkout has no auto-renewal checkbox, and none can be ticked by default. A required checkbox custom field can ask for consent.
  - Polar emails a reminder 7 days before each yearly renewal. Several US states want 15 to 45 days, which needs a legal check.
- Builds released from now on read `keybumps_updates_until`, so they honor renewals as soon as the site writes it.
- If Polar trims customer metadata from its public responses (they also carry the customer's email and billing details), renewals stop reaching the app, and decision 3's fallback is needed.
- The appcast lists only the newest release. A lapsed customer on an older version can't get the last covered one through Sparkle once a newer one ships, and Settings › Changelog's link to keybumps.app/changelog is how they find it there, so that page should link each release's download.
- `CONTEXT.md` gains Update year and Renewal.
