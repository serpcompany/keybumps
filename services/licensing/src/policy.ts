// Lease timing rules from docs/adr/0001-licensing.md §7. All times are Unix seconds.

export const DAY = 86_400;
export const REFRESH_INTERVAL = 7 * DAY;
export const LEASE_LIFETIME = 45 * DAY;
export const SUBSCRIPTION_GRACE = 7 * DAY;

export interface LeaseWindow {
  refreshAfter: number;
  expiresAt: number;
}

/**
 * A Lease refreshes after about a week and expires after about 45 days. A License with
 * `validUntil` (a subscription or fixed term) refreshes no later than `validUntil` and
 * expires no later than `validUntil` plus the grace period.
 */
export function leaseWindow(now: number, validUntil: number | null): LeaseWindow {
  let refreshAfter = now + REFRESH_INTERVAL;
  let expiresAt = now + LEASE_LIFETIME;
  if (validUntil !== null) {
    refreshAfter = Math.min(refreshAfter, Math.max(now, validUntil));
    expiresAt = Math.min(expiresAt, validUntil + SUBSCRIPTION_GRACE);
  }
  return { refreshAfter, expiresAt };
}

/** Whether the service may still issue a Lease for a License with this `validUntil`. */
export function isWithinTerm(now: number, validUntil: number | null): boolean {
  return validUntil === null || now < validUntil + SUBSCRIPTION_GRACE;
}
