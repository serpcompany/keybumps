import { describe, expect, it } from "vitest";
import { DAY, isWithinTerm, leaseWindow } from "../src/policy";

const now = 1_800_000_000;

describe("leaseWindow", () => {
  it("gives perpetual Licenses a 7-day refresh and 45-day expiry", () => {
    expect(leaseWindow(now, null)).toEqual({ refreshAfter: now + 7 * DAY, expiresAt: now + 45 * DAY });
  });

  it("caps subscription expiry at validUntil plus grace", () => {
    const validUntil = now + 20 * DAY;
    expect(leaseWindow(now, validUntil)).toEqual({ refreshAfter: now + 7 * DAY, expiresAt: validUntil + 7 * DAY });
  });

  it("refreshes no later than validUntil", () => {
    const validUntil = now + 2 * DAY;
    expect(leaseWindow(now, validUntil).refreshAfter).toBe(validUntil);
  });

  it("retries daily inside the grace period, never past expiry", () => {
    expect(leaseWindow(now, now - DAY)).toEqual({ refreshAfter: now + DAY, expiresAt: now + 6 * DAY });
    expect(leaseWindow(now, now - 6.5 * DAY)).toEqual({ refreshAfter: now + 0.5 * DAY, expiresAt: now + 0.5 * DAY });
  });
});

describe("isWithinTerm", () => {
  it("allows perpetual Licenses and the grace period, then stops", () => {
    expect(isWithinTerm(now, null)).toBe(true);
    expect(isWithinTerm(now, now - 6 * DAY)).toBe(true);
    expect(isWithinTerm(now, now - 7 * DAY)).toBe(false);
  });
});
