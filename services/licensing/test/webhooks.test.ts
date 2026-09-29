import { env, exports } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { PolarAdapter } from "../src/providers/polar";

const SECRET = "polar_whs_test_secret";
const PRODUCT_REF = "prod_keybumps";
const iso = (seconds: number) => new Date(seconds * 1000).toISOString();
const now = () => Math.floor(Date.now() / 1000);
let deliveries = 0;

async function sign(id: string, timestamp: number, body: string, secret: string | Uint8Array = SECRET): Promise<string> {
  const raw = typeof secret === "string" ? new TextEncoder().encode(secret) : secret;
  const key = await crypto.subtle.importKey("raw", raw, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${id}.${timestamp}.${body}`)));
  return `v1,${btoa(String.fromCharCode(...signature))}`;
}

async function deliver(payload: unknown, options: { id?: string; timestamp?: number; secret?: string | Uint8Array } = {}) {
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

  it("accepts whsec_ secrets keyed with their base64-decoded bytes", async () => {
    const raw = crypto.getRandomValues(new Uint8Array(24));
    const adapter = new PolarAdapter(`whsec_${btoa(String.fromCharCode(...raw))}`);
    const body = JSON.stringify({ type: "checkout.created", data: {} });
    const timestamp = now();
    const request = new Request("https://licensing.test/webhooks/polar", {
      method: "POST",
      headers: { "webhook-id": "msg_whsec", "webhook-timestamp": String(timestamp), "webhook-signature": await sign("msg_whsec", timestamp, body, raw) },
      body,
    });
    expect(await adapter.verifyWebhook(request)).toEqual({ eventId: "msg_whsec", event: { type: "ignored" } });
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

  it("ignores a retired Offer named in metadata", async () => {
    await admin("/admin/offers", { id: "keybumps-old", product: "keybumps", provider: "polar", providerRef: "prod_retired", kind: "perpetual", active: false });
    expect(await deliver(order({ product_id: "prod_retired", metadata: { offer: "keybumps-old" } }))).toBe(422);
  });

  it("mints on retry when an earlier delivery recorded the order but failed before minting", async () => {
    const paid = order({ customer_id: "cus_m", customer: { id: "cus_m", email: "m@example.com" } });
    await env.DB.batch([
      env.DB.prepare("INSERT INTO customers (id, email, provider, provider_ref, created_at) VALUES ('c_m', 'm@example.com', 'polar', 'cus_m', 0)"),
      env.DB.prepare("INSERT INTO orders (id, provider, provider_ref, customer_id, offer_id, status, created_at) VALUES ('o_m', 'polar', ?, 'c_m', 'keybumps-launch-a', 'paid', 0)").bind(paid.data.id),
    ]);
    expect(await deliver(paid)).toBe(200);
    expect(await deliver(paid)).toBe(200);
    expect(await licensesFor("m@example.com")).toHaveLength(1);
  });

  it("never falls back to another Offer when metadata names an unknown one", async () => {
    expect(await deliver(order({ metadata: { offer: "keybumps-typo" } }))).toBe(422);
  });

  it("asks Polar to retry when no Offer matches the product", async () => {
    expect(await deliver(order({ product_id: "prod_unknown" }))).toBe(422);
  });

  it("rejects a malformed order", async () => {
    expect(await deliver(order({ customer: null, customer_id: null }))).toBe(400);
  });
});

describe("refunds", () => {
  it("asks Polar to retry a refund that arrives before its paid order", async () => {
    const paid = order({ customer_id: "cus_early", customer: { id: "cus_early", email: "early@example.com" } });
    const refund = { type: "order.refunded", data: { ...paid.data, status: "refunded" } };
    expect(await deliver(refund)).toBe(409);
    await deliver(paid);
    expect(await deliver(refund)).toBe(200);
    expect((await licensesFor("early@example.com"))[0].status).toBe("revoked");
  });

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

  const subscriptionOrder = (reason: string, periodEnd: number, sub = "sub_1", email = "s@example.com") =>
    order({
      billing_reason: reason,
      product_id: "prod_monthly",
      customer_id: `cus_${sub}`,
      customer: { id: `cus_${sub}`, email },
      subscription_id: sub,
      subscription: { id: sub, current_period_end: iso(periodEnd) },
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

  it("applies subscription events that arrive before the paid order", async () => {
    const periodEnd = now() + 30 * 86_400;
    await deliver({ type: "subscription.active", data: { id: "sub_3", status: "active", current_period_end: iso(periodEnd) } });
    const paid = subscriptionOrder("subscription_create", periodEnd, "sub_3", "early-sub@example.com");
    (paid.data as Record<string, unknown>).subscription = null;
    await deliver(paid);
    expect((await licensesFor("early-sub@example.com"))[0]).toMatchObject({ status: "active", validUntil: periodEnd });

    await deliver({ type: "subscription.revoked", data: { id: "sub_4", status: "canceled", ended_at: iso(now()) } });
    await deliver(subscriptionOrder("subscription_create", periodEnd, "sub_4", "ended-first@example.com"));
    expect((await licensesFor("ended-first@example.com"))[0].status).toBe("revoked");
  });

  it("extends instead of minting on a plan change, and doesn't extend a past-due subscription", async () => {
    const firstEnd = now() + 30 * 86_400;
    await deliver(subscriptionOrder("subscription_create", firstEnd, "sub_2", "plan@example.com"));
    await deliver(subscriptionOrder("subscription_update", firstEnd + 86_400, "sub_2", "plan@example.com"));
    const licenses = await licensesFor("plan@example.com");
    expect(licenses).toHaveLength(1);
    expect(licenses[0].validUntil).toBe(firstEnd + 86_400);

    await deliver({ type: "subscription.updated", data: { id: "sub_2", status: "past_due", current_period_end: iso(firstEnd + 60 * 86_400) } });
    expect((await licensesFor("plan@example.com"))[0].validUntil).toBe(firstEnd + 86_400);
  });
});

it("acknowledges event types it ignores", async () => {
  expect(await deliver({ type: "checkout.created", data: { id: "chk_1" } })).toBe(200);
});
