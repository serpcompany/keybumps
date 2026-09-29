import { exports } from "cloudflare:workers";

const SECRET = "polar_whs_test_secret";
let deliveries = 0;

const now = () => Math.floor(Date.now() / 1000);

export async function sign(id: string, timestamp: number, body: string, secret: string | Uint8Array = SECRET): Promise<string> {
  const raw = typeof secret === "string" ? new TextEncoder().encode(secret) : secret;
  const key = await crypto.subtle.importKey("raw", raw, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${id}.${timestamp}.${body}`)));
  return `v1,${btoa(String.fromCharCode(...signature))}`;
}

export async function deliver(payload: unknown, options: { id?: string; timestamp?: number; secret?: string | Uint8Array } = {}) {
  const id = options.id ?? `msg_${++deliveries}_${Math.random()}`;
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

/** A Polar `order.paid` payload for a one-time purchase. */
export function order(email: string, overrides: Record<string, unknown> = {}) {
  const customer = `cus_${email}`;
  return {
    type: "order.paid",
    timestamp: new Date().toISOString(),
    data: {
      id: `ord_${++deliveries}_${Math.random()}`,
      status: "paid",
      billing_reason: "purchase",
      customer_id: customer,
      customer: { id: customer, email },
      product_id: "prod_keybumps",
      subscription_id: null,
      metadata: {},
      ...overrides,
    },
  };
}
