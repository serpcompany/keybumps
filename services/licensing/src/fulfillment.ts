// Applies provider-neutral events to Licenses. Every handler is idempotent so a redelivered
// webhook changes nothing, and a period end only ever moves forward so late deliveries are harmless.

import { DAY } from "./policy";
import { issueLicense, revokeLicense } from "./licenses";
import type { NormalizedEvent, NormalizedOrder } from "./providers/types";

/** Used only if a subscription order arrives without its period end; the next subscription event corrects it. */
const FALLBACK_SUBSCRIPTION_PERIOD = 35 * DAY;

interface OfferRow {
  id: string;
  product_id: string;
  kind: "perpetual" | "update_window" | "subscription";
  updates_days: number | null;
  max_activations: number;
}

export class UnknownOfferError extends Error {}

export async function applyEvent(db: D1Database, provider: string, event: NormalizedEvent, now: number): Promise<void> {
  switch (event.type) {
    case "order.paid":
      return orderPaid(db, provider, event.order, now);
    case "order.refunded":
      return orderRefunded(db, provider, event.orderRef, now);
    case "subscription.period":
      await db
        .prepare("UPDATE licenses SET valid_until = MAX(COALESCE(valid_until, 0), ?) WHERE subscription_ref = ? AND status = 'active'")
        .bind(event.currentPeriodEnd, event.subscriptionRef)
        .run();
      return;
    case "subscription.ended":
      await db
        .prepare("UPDATE licenses SET status = 'revoked', revoked_reason = 'subscription_ended', revoked_at = ? WHERE subscription_ref = ? AND status = 'active'")
        .bind(now, event.subscriptionRef)
        .run();
      return;
    case "ignored":
      return;
  }
}

async function orderPaid(db: D1Database, provider: string, order: NormalizedOrder, now: number): Promise<void> {
  // Renewals and plan changes extend the subscription's existing License instead of minting another.
  const startsSubscription = order.billingReason === "purchase" || order.billingReason === "subscription_create";
  if (order.subscription && (!startsSubscription || (await hasSubscriptionLicense(db, order.subscription.ref)))) {
    if (order.subscription.currentPeriodEnd !== null) {
      await db
        .prepare("UPDATE licenses SET valid_until = MAX(COALESCE(valid_until, 0), ?) WHERE subscription_ref = ? AND status = 'active'")
        .bind(order.subscription.currentPeriodEnd, order.subscription.ref)
        .run();
    }
    return;
  }

  const existing = await db
    .prepare(
      `SELECT o.id, o.customer_id, o.offer_id, l.id AS license_id
       FROM orders o LEFT JOIN licenses l ON l.order_id = o.id WHERE o.provider = ? AND o.provider_ref = ?`,
    )
    .bind(provider, order.ref)
    .first<{ id: string; customer_id: string; offer_id: string; license_id: string | null }>();
  // Fulfilled already, or recorded by a delivery that failed before minting: mint only if missing.
  if (existing) {
    if (existing.license_id) return;
    const offer = await offerById(db, existing.offer_id);
    if (!offer) throw new UnknownOfferError();
    return mint(db, offer, order, existing.customer_id, existing.id, now);
  }

  const offer = await findOffer(db, provider, order);
  if (!offer) throw new UnknownOfferError();

  const customerId = await upsertCustomer(db, provider, order.customer, now);
  const orderId = crypto.randomUUID();
  const inserted = await db
    .prepare(
      `INSERT OR IGNORE INTO orders (id, provider, provider_ref, customer_id, offer_id, status, created_at)
       VALUES (?, ?, ?, ?, ?, 'paid', ?)`,
    )
    .bind(orderId, provider, order.ref, customerId, offer.id, now)
    .run();
  // A concurrent delivery recorded it first and mints it (or its retry will).
  if (inserted.meta.changes === 0) return;
  return mint(db, offer, order, customerId, orderId, now);
}

async function hasSubscriptionLicense(db: D1Database, subscriptionRef: string): Promise<boolean> {
  return (await db.prepare("SELECT 1 FROM licenses WHERE subscription_ref = ? LIMIT 1").bind(subscriptionRef).first()) !== null;
}

/** licenses(order_id) is unique, so a concurrent mint for the same order fails instead of duplicating. */
async function mint(db: D1Database, offer: OfferRow, order: NormalizedOrder, customerId: string, orderId: string, now: number): Promise<void> {
  const subscription = offer.kind === "subscription" ? order.subscription : null;
  await issueLicense(
    db,
    {
      product: offer.product_id,
      customerId,
      orderId,
      subscriptionRef: subscription?.ref ?? null,
      validUntil: offer.kind === "subscription" ? (subscription?.currentPeriodEnd ?? now + FALLBACK_SUBSCRIPTION_PERIOD) : null,
      updatesUntil: offer.kind === "update_window" && offer.updates_days !== null ? now + offer.updates_days * DAY : null,
      maxActivations: offer.max_activations,
    },
    now,
  );
}

async function orderRefunded(db: D1Database, provider: string, orderRef: string, now: number): Promise<void> {
  const row = await db
    .prepare("SELECT l.id FROM licenses l JOIN orders o ON o.id = l.order_id WHERE o.provider = ? AND o.provider_ref = ?")
    .bind(provider, orderRef)
    .first<{ id: string }>();
  await db.prepare("UPDATE orders SET status = 'refunded' WHERE provider = ? AND provider_ref = ?").bind(provider, orderRef).run();
  if (row) await revokeLicense(db, row.id, "refunded", now);
}

const OFFER_COLUMNS = "id, product_id, kind, updates_days, max_activations";

async function offerById(db: D1Database, id: string): Promise<OfferRow | null> {
  return db.prepare(`SELECT ${OFFER_COLUMNS} FROM offers WHERE id = ?`).bind(id).first<OfferRow>();
}

async function findOffer(db: D1Database, provider: string, order: NormalizedOrder): Promise<OfferRow | null> {
  const columns = OFFER_COLUMNS;
  if (order.offerId) {
    // The metadata must name an active Offer for the product actually bought.
    const offer = await db
      .prepare(`SELECT ${columns} FROM offers WHERE id = ? AND provider = ? AND provider_ref = ? AND active = 1`)
      .bind(order.offerId, provider, order.productRef)
      .first<OfferRow>();
    if (offer) return offer;
  }
  return db
    .prepare(`SELECT ${columns} FROM offers WHERE provider = ? AND provider_ref = ? AND active = 1 ORDER BY created_at LIMIT 1`)
    .bind(provider, order.productRef)
    .first<OfferRow>();
}

async function upsertCustomer(db: D1Database, provider: string, customer: NormalizedOrder["customer"], now: number): Promise<string> {
  await db
    .prepare(
      `INSERT INTO customers (id, email, provider, provider_ref, created_at) VALUES (?, ?, ?, ?, ?)
       ON CONFLICT (provider, provider_ref) DO UPDATE SET email = excluded.email`,
    )
    .bind(crypto.randomUUID(), customer.email.toLowerCase(), provider, customer.ref, now)
    .run();
  const row = await db
    .prepare("SELECT id FROM customers WHERE provider = ? AND provider_ref = ?")
    .bind(provider, customer.ref)
    .first<{ id: string }>();
  return row!.id;
}
