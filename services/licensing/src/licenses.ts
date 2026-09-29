// License persistence. Shared by admin routes now and by provider webhooks later.

import { generateLicenseKey } from "./keys";

export interface LicenseRow {
  id: string;
  product_id: string;
  license_key: string;
  customer_id: string | null;
  order_id: string | null;
  valid_until: number | null;
  updates_until: number | null;
  max_activations: number;
  status: "active" | "revoked";
}

export interface IssueLicenseInput {
  product: string;
  customerId?: string | null;
  orderId?: string | null;
  subscriptionRef?: string | null;
  validUntil?: number | null;
  updatesUntil?: number | null;
  maxActivations?: number;
}

export const DEFAULT_MAX_ACTIVATIONS = 3;

export async function productKeyPrefix(db: D1Database, product: string): Promise<string | null> {
  const row = await db.prepare("SELECT key_prefix FROM products WHERE id = ?").bind(product).first<{ key_prefix: string }>();
  return row?.key_prefix ?? null;
}

export async function issueLicense(db: D1Database, input: IssueLicenseInput, now: number): Promise<LicenseRow> {
  const prefix = await productKeyPrefix(db, input.product);
  if (prefix === null) throw new Error("unknown product");
  const row: LicenseRow = {
    id: crypto.randomUUID(),
    product_id: input.product,
    license_key: generateLicenseKey(prefix),
    customer_id: input.customerId ?? null,
    order_id: input.orderId ?? null,
    valid_until: input.validUntil ?? null,
    updates_until: input.updatesUntil ?? null,
    max_activations: input.maxActivations ?? DEFAULT_MAX_ACTIVATIONS,
    status: "active",
  };
  await db
    .prepare(
      `INSERT INTO licenses (id, product_id, license_key, customer_id, order_id, subscription_ref,
        valid_until, updates_until, max_activations, status, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?)`,
    )
    .bind(
      row.id, row.product_id, row.license_key, row.customer_id, row.order_id, input.subscriptionRef ?? null,
      row.valid_until, row.updates_until, row.max_activations, now,
    )
    .run();
  return row;
}

export async function findLicense(db: D1Database, product: string, key: string): Promise<LicenseRow | null> {
  return db
    .prepare(
      `SELECT id, product_id, license_key, customer_id, order_id, valid_until, updates_until, max_activations, status
       FROM licenses WHERE product_id = ? AND license_key = ?`,
    )
    .bind(product, key)
    .first<LicenseRow>();
}

export async function revokeLicense(db: D1Database, licenseId: string, reason: string, now: number): Promise<void> {
  await db
    .prepare("UPDATE licenses SET status = 'revoked', revoked_reason = ?, revoked_at = ? WHERE id = ? AND status = 'active'")
    .bind(reason, now, licenseId)
    .run();
}

export async function resetActivations(db: D1Database, licenseId: string, now: number): Promise<void> {
  await db.batch([
    db.prepare("DELETE FROM activations WHERE license_id = ?").bind(licenseId),
    db.prepare("UPDATE licenses SET last_reset_at = ? WHERE id = ?").bind(now, licenseId),
  ]);
}

export async function activationCount(db: D1Database, licenseId: string): Promise<number> {
  const row = await db.prepare("SELECT COUNT(*) AS count FROM activations WHERE license_id = ?").bind(licenseId).first<{ count: number }>();
  return row?.count ?? 0;
}

/** Records a seen device that is already activated. Returns false when it isn't. */
export async function touchActivation(db: D1Database, licenseId: string, deviceHash: string, now: number): Promise<boolean> {
  const result = await db
    .prepare("UPDATE activations SET last_seen_at = ? WHERE license_id = ? AND device_hash = ?")
    .bind(now, licenseId, deviceHash)
    .run();
  return result.meta.changes > 0;
}

/**
 * Adds a device only while the License has a free slot. A single conditional INSERT keeps
 * two concurrent activations from both taking the last slot.
 */
export async function addActivation(db: D1Database, license: LicenseRow, deviceHash: string, now: number): Promise<boolean> {
  const result = await db
    .prepare(
      `INSERT OR IGNORE INTO activations (license_id, device_hash, created_at, last_seen_at)
       SELECT ?, ?, ?, ? WHERE (SELECT COUNT(*) FROM activations WHERE license_id = ?) < ?`,
    )
    .bind(license.id, deviceHash, now, now, license.id, license.max_activations)
    .run();
  return result.meta.changes > 0;
}

export async function removeActivation(db: D1Database, licenseId: string, deviceHash: string): Promise<void> {
  await db.prepare("DELETE FROM activations WHERE license_id = ? AND device_hash = ?").bind(licenseId, deviceHash).run();
}
