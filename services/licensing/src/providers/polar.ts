// Polar adapter. Polar signs webhooks with the Standard Webhooks scheme: HMAC-SHA256 over
// `${webhook-id}.${webhook-timestamp}.${body}`, sent as `v1,<base64>` in `webhook-signature`.
// Like Polar's SDK, the key is either the secret's UTF-8 bytes or, for `whsec_<base64>`
// secrets, its base64-decoded bytes; both are tried.

import type { NormalizedEvent, NormalizedOrder, ProviderAdapter, VerifiedWebhook } from "./types";

const TOLERANCE_SECONDS = 5 * 60;

type Json = Record<string, any>;

export class PolarAdapter implements ProviderAdapter {
  readonly name = "polar";

  constructor(
    private readonly secret: string,
    private readonly now: () => number = () => Math.floor(Date.now() / 1000),
  ) {}

  async verifyWebhook(request: Request): Promise<VerifiedWebhook | null> {
    const id = request.headers.get("webhook-id");
    const timestamp = request.headers.get("webhook-timestamp");
    const signatures = request.headers.get("webhook-signature");
    if (!id || !timestamp || !signatures || !/^\d+$/.test(timestamp)) return null;
    if (Math.abs(this.now() - Number(timestamp)) > TOLERANCE_SECONDS) return null;

    const body = await request.text();
    const message = `${id}.${timestamp}.${body}`;
    const expected = await Promise.all(signingKeys(this.secret).map((key) => hmacBase64(key, message)));
    const valid = signatures
      .split(" ")
      .some((entry) => entry.startsWith("v1,") && expected.some((signature) => timingSafeEqual(entry.slice(3), signature)));
    if (!valid) return null;

    let payload: Json;
    try {
      payload = JSON.parse(body);
    } catch {
      return null;
    }
    return { eventId: id, event: normalize(payload) };
  }
}

export function normalize(payload: Json): NormalizedEvent {
  const data: Json = payload?.data ?? {};
  switch (payload?.type) {
    case "order.paid":
      return { type: "order.paid", order: normalizeOrder(data) };
    case "order.refunded":
      // Only a full refund revokes; partial refunds keep the License.
      return data.status === "refunded" && typeof data.id === "string"
        ? { type: "order.refunded", orderRef: data.id }
        : { type: "ignored" };
    case "subscription.active":
    case "subscription.updated":
    case "subscription.uncanceled":
    case "subscription.cycled":
    case "subscription.canceled":
    case "subscription.revoked":
      return normalizeSubscription(payload.type, data);
    default:
      return { type: "ignored" };
  }
}

function normalizeOrder(data: Json): NormalizedOrder {
  const subscriptionRef = data.subscription_id ?? data.subscription?.id ?? null;
  const reason = data.billing_reason;
  return {
    ref: requireString(data.id),
    customer: {
      ref: requireString(data.customer_id ?? data.customer?.id),
      email: requireString(data.customer?.email),
    },
    productRef: requireString(data.product_id ?? data.product?.id),
    offerId: typeof data.metadata?.offer === "string" ? data.metadata.offer : null,
    billingReason: reason === "purchase" || reason === "subscription_create" || reason === "subscription_cycle" ? reason : "other",
    subscription: subscriptionRef
      ? { ref: subscriptionRef, currentPeriodEnd: seconds(data.subscription?.current_period_end) }
      : null,
  };
}

function normalizeSubscription(type: string, data: Json): NormalizedEvent {
  if (typeof data.id !== "string") return { type: "ignored" };
  const ended = type === "subscription.revoked" || (data.ended_at != null && data.status !== "active" && data.status !== "trialing");
  if (ended) return { type: "subscription.ended", subscriptionRef: data.id };
  const currentPeriodEnd = seconds(data.current_period_end);
  if (currentPeriodEnd === null) return { type: "ignored" };
  return { type: "subscription.period", subscriptionRef: data.id, currentPeriodEnd };
}

function requireString(value: unknown): string {
  if (typeof value !== "string" || value.length === 0) throw new Error("malformed Polar order");
  return value;
}

function seconds(iso: unknown): number | null {
  if (typeof iso !== "string") return null;
  const ms = Date.parse(iso);
  return Number.isNaN(ms) ? null : Math.floor(ms / 1000);
}

function signingKeys(secret: string): Uint8Array[] {
  const utf8 = new TextEncoder().encode(secret);
  const keys = [utf8];
  try {
    const encoded = secret.startsWith("whsec_") ? secret.slice(6) : secret;
    const decoded = Uint8Array.from(atob(encoded), (char) => char.charCodeAt(0));
    if (decoded.length > 0) keys.push(decoded);
  } catch {
    // Not base64; only the UTF-8 key applies.
  }
  return keys;
}

async function hmacBase64(secret: Uint8Array, message: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", secret, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message)));
  let binary = "";
  for (const byte of signature) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
