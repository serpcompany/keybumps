import { exports } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";

const SECRET = "polar_whs_test_secret";
const PRODUCT_REF = "prod_keybumps";
const iso = (seconds: number) => new Date(seconds * 1000).toISOString();
const now = () => Math.floor(Date.now() / 1000);
let deliveries = 0;

async function sign(id: string, timestamp: number, body: string, secret = SECRET): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${id}.${timestamp}.${body}`)));
  return `v1,${btoa(String.fromCharCode(...signature))}`;
}

async function deliver(payload: unknown, options: { id?: string; timestamp?: number; secret?: string } = {}) {
  const id = options.id ?? `msg_${++deliveries}`;
  const timestamp = options.timestamp ?? now();
  const body = JSON.stringify(payload);
  const response = await exports.default.fetch("https://licensing.test/webhooks/polar", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "webhook-id": id,
      "webhook-timestamp": String(timestamp),
      "webhook-signature": await sign(id, timestamp, body, options.secret),
    },
    body,
  });
  return response.status;
}

async function admin(path: string, body: unknown) {
  const response = await exports.default.fetch(`https://licensing.test${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: "Bearer test-admin-token" },
    body: JSON.stringify(body),
  });
  return { status: response.status, body: (await response.json()) as Record<string, any> };
}

const licensesFor = async (email: string) => (await admin("/admin/licenses/by-email", { email })).body.licenses as Record<string, any>[];

function order(overrides: Record<string, any> = {}) {
  return {
    type: "order.paid",
    timestamp: iso(now()),
    data: {
      id: `ord_${deliveries}_${Math.random()}`,
      status: "paid",
      billing_reason: "purchase",
      customer_id: "cus_1",
      customer: { id: "cus_1", email: "Buyer@Example.com" },
      product_id: PRODUCT_REF,
      subscription_id: null,
      metadata: {},
      ...overrides,
    },
  };
}

beforeEach(async () => {
  await admin("/admin/offers", { id: "keybumps-launch-a", product: "keybumps", provider: "polar", providerRef: PRODUCT_REF, kind: "perpetual" });
});

describe("signature verification", () => {
  it("rejects a wrong secret, a stale timestamp, and a missing signature", async () => {
    expect(await deliver(order(), { secret: "wrong" })).toBe(401);
    expect(await deliver(order(), { timestamp: now() - 600 })).toBe(401);
    const response = await exports.default.fetch("https://licensing.test/webhooks/polar", { method: "POST", body: "{}" });
    expect(response.status).toBe(401);
  });

  it("returns not_found for providers without a configured adapter", async () => {
    const response = await exports.default.fetch("https://licensing.test/webhooks/stripe", { method: "POST", body: "{}" });
    expect(response.status).toBe(404);
  });
});

describe("order.paid", () => {
  it("issues one perpetual License per order, even when redelivered", async () => {
    const paid = order();
    expect(await deliver(paid, { id: "msg_same" })).toBe(200);
    expect(await deliver(paid, { id: "msg_same" })).toBe(200);
    expect(await deliver(paid, { id: "msg_retry_with_new_id" })).toBe(200);
    const licenses = await licensesFor("buyer@example.com");
    expect(licenses).toHaveLength(1);
    expect(licenses[0]).toMatchObject({ product: "keybumps", status: "active", validUntil: null, updatesUntil: null });
    expect(licenses[0].key).toMatch(/^KB(-[0-9A-Z]{4}){4}$/);
  });

  it("uses the Offer named in checkout metadata", async () => {
    await admin("/admin/offers", { id: "keybumps-launch-b", product: "keybumps", provider: "polar", providerRef: PRODUCT_REF, kind: "update_window", updatesDays: 365, maxActivations: 2 });
    await deliver(order({ customer_id: "cus_b", customer: { id: "cus_b", email: "b@example.com" }, metadata: { offer: "keybumps-launch-b" } }));
    const [license] = await licensesFor("b@example.com");
    expect(license.updatesUntil - now()).toBeGreaterThan(364 * 86_400);
  });

  it("asks Polar to retry when no Offer matches the product", async () => {
    expect(await deliver(order({ product_id: "prod_unknown" }))).toBe(422);
  });

  it("rejects a malformed order", async () => {
    expect(await deliver(order({ customer: null, customer_id: null }))).toBe(400);
  });
});

describe("refunds", () => {
  it("revokes on a full refund and ignores a partial one", async () => {
    const paid = order({ customer_id: "cus_r", customer: { id: "cus_r", email: "r@example.com" } });
    await deliver(paid);
    await deliver({ type: "order.refunded", data: { ...paid.data, status: "partially_refunded" } });
    expect((await licensesFor("r@example.com"))[0].status).toBe("active");
    await deliver({ type: "order.refunded", data: { ...paid.data, status: "refunded" } });
    expect((await licensesFor("r@example.com"))[0].status).toBe("revoked");
  });
});

describe("subscriptions", () => {
  beforeEach(async () => {
    await admin("/admin/offers", { id: "keybumps-monthly", product: "keybumps", provider: "polar", providerRef: "prod_monthly", kind: "subscription" });
  });

  const subscriptionOrder = (reason: string, periodEnd: number) =>
    order({
      billing_reason: reason,
      product_id: "prod_monthly",
      customer_id: "cus_s",
      customer: { id: "cus_s", email: "s@example.com" },
      subscription_id: "sub_1",
      subscription: { id: "sub_1", current_period_end: iso(periodEnd) },
    });

  it("sets validUntil from the period, extends on renewal, and revokes when it ends", async () => {
    const firstEnd = now() + 30 * 86_400;
    await deliver(subscriptionOrder("subscription_create", firstEnd));
    expect((await licensesFor("s@example.com"))[0].validUntil).toBe(firstEnd);

    const secondEnd = firstEnd + 30 * 86_400;
    await deliver(subscriptionOrder("subscription_cycle", secondEnd));
    const licenses = await licensesFor("s@example.com");
    expect(licenses).toHaveLength(1);
    expect(licenses[0].validUntil).toBe(secondEnd);

    // A late, older event never moves the period backwards.
    await deliver({ type: "subscription.updated", data: { id: "sub_1", status: "active", current_period_end: iso(firstEnd) } });
    expect((await licensesFor("s@example.com"))[0].validUntil).toBe(secondEnd);

    // Canceling at period end keeps the License until then.
    await deliver({ type: "subscription.canceled", data: { id: "sub_1", status: "active", cancel_at_period_end: true, ended_at: null, current_period_end: iso(secondEnd) } });
    expect((await licensesFor("s@example.com"))[0].status).toBe("active");

    await deliver({ type: "subscription.revoked", data: { id: "sub_1", status: "canceled", ended_at: iso(now()) } });
    expect((await licensesFor("s@example.com"))[0].status).toBe("revoked");
  });
});

it("acknowledges event types it ignores", async () => {
  expect(await deliver({ type: "checkout.created", data: { id: "chk_1" } })).toBe(200);
});
