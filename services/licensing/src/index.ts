// SERP licensing service (docs/adr/0001-licensing.md).
// Never log License Keys, device hashes, emails, or request bodies.

import { normalizeLicenseKey } from "./keys";
import { importSigningKey, signLease, type LeasePayload, type SigningKey } from "./lease";
import {
  activationCount,
  addActivation,
  findLicense,
  issueLicense,
  productKeyPrefix,
  removeActivation,
  resetActivations,
  revokeLicense,
  touchActivation,
  type LicenseRow,
} from "./licenses";
import { applyEvent, NotYetKnownError, UnknownOfferError } from "./fulfillment";
import { deliverPendingKeys, ResendMailer, type KeyMailer } from "./mailer";
import { isWithinTerm, leaseWindow } from "./policy";
import { PolarAdapter } from "./providers/polar";
import type { ProviderAdapter } from "./providers/types";

export interface Env {
  DB: D1Database;
  /** `{"kid": "...", "jwk": {Ed25519 private JWK}}` */
  LEASE_SIGNING_KEY: string;
  ADMIN_TOKEN: string;
  /** Polar webhook endpoint secret. Webhooks from Polar are rejected while it is unset. */
  POLAR_WEBHOOK_SECRET?: string;
  /** Resend API key. Keys aren't emailed while it is unset. */
  RESEND_API_KEY?: string;
  /** Sender, e.g. `Keybumps <licenses@keybumps.app>`. */
  EMAIL_FROM?: string;
  /** Optional Workers rate-limiting binding, keyed per License Key. */
  KEY_LIMITER?: { limit(options: { key: string }): Promise<{ success: boolean }> };
}

/** Error codes the app relies on. Keep them stable. */
export type ErrorCode =
  | "bad_request"
  | "unauthorized"
  | "not_found"
  | "rate_limited"
  | "invalid_key"
  | "revoked"
  | "expired"
  | "activation_limit"
  | "not_activated";

const STATUS: Record<ErrorCode, number> = {
  bad_request: 400,
  unauthorized: 401,
  not_found: 404,
  rate_limited: 429,
  invalid_key: 404,
  revoked: 403,
  expired: 403,
  activation_limit: 409,
  not_activated: 403,
};

class ApiError extends Error {
  constructor(readonly code: ErrorCode) {
    super(code);
  }
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });

/** 2100-01-01T00:00:00Z */
const MAX_UNIX_SECONDS = 4_102_444_800;

const nowSeconds = () => Math.floor(Date.now() / 1000);

let cachedSigningKey: { secret: string; key: SigningKey } | undefined;
async function signingKey(env: Env): Promise<SigningKey> {
  if (cachedSigningKey?.secret !== env.LEASE_SIGNING_KEY) {
    cachedSigningKey = { secret: env.LEASE_SIGNING_KEY, key: await importSigningKey(env.LEASE_SIGNING_KEY) };
  }
  return cachedSigningKey.key;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      return await route(request, env);
    } catch (error) {
      if (error instanceof ApiError) return json({ error: error.code }, STATUS[error.code]);
      return json({ error: "internal" }, 500);
    }
  },
} satisfies ExportedHandler<Env>;

async function route(request: Request, env: Env): Promise<Response> {
  const { pathname } = new URL(request.url);
  if (request.method !== "POST") throw new ApiError("not_found");
  const webhook = pathname.match(/^\/webhooks\/([a-z]+)$/);
  if (webhook) return receiveWebhook(request, env, webhook[1]);
  switch (pathname) {
    case "/v1/activate":
      return activate(await clientRequest(request, env), env);
    case "/v1/refresh":
      return refresh(await clientRequest(request, env), env);
    case "/v1/deactivate":
      return deactivate(await clientRequest(request, env), env);
    case "/v1/resend-key":
      return resendKey(await readJson(request), env);
    case "/admin/licenses":
      await requireAdmin(request, env);
      return adminIssue(await readJson(request), env);
    case "/admin/offers":
      await requireAdmin(request, env);
      return adminUpsertOffer(await readJson(request), env);
    case "/admin/licenses/by-email":
      await requireAdmin(request, env);
      return adminLicensesByEmail(await readJson(request), env);
    case "/admin/licenses/lookup":
      await requireAdmin(request, env);
      return adminLookup(await readJson(request), env);
    case "/admin/licenses/revoke":
      await requireAdmin(request, env);
      return adminRevoke(await readJson(request), env);
    case "/admin/licenses/reset-activations":
      await requireAdmin(request, env);
      return adminReset(await readJson(request), env);
    default:
      throw new ApiError("not_found");
  }
}

// MARK: - App endpoints

interface ClientRequest {
  product: string;
  key: string;
  deviceHash: string;
}

async function clientRequest(request: Request, env: Env): Promise<ClientRequest> {
  const body = await readJson(request);
  const product = body.product;
  const key = body.key;
  const deviceHash = typeof body.deviceHash === "string" ? body.deviceHash.toLowerCase() : body.deviceHash;
  if (typeof product !== "string" || !/^[a-z0-9-]{1,32}$/.test(product)) throw new ApiError("bad_request");
  if (typeof key !== "string" || key.length === 0 || key.length > 64) throw new ApiError("bad_request");
  if (typeof deviceHash !== "string" || !/^[0-9a-f]{64}$/.test(deviceHash)) throw new ApiError("bad_request");
  const prefix = await productKeyPrefix(env.DB, product);
  if (prefix === null) throw new ApiError("invalid_key");
  const normalized = normalizeLicenseKey(key, prefix);
  if (env.KEY_LIMITER) {
    const { success } = await env.KEY_LIMITER.limit({ key: `${product}:${normalized}` });
    if (!success) throw new ApiError("rate_limited");
  }
  return { product, key: normalized, deviceHash };
}

async function entitledLicense(env: Env, request: ClientRequest, now: number): Promise<LicenseRow> {
  const license = await findLicense(env.DB, request.product, request.key);
  if (!license) throw new ApiError("invalid_key");
  if (license.status === "revoked") throw new ApiError("revoked");
  if (!isWithinTerm(now, license.valid_until)) throw new ApiError("expired");
  return license;
}

async function activate(request: ClientRequest, env: Env): Promise<Response> {
  const now = nowSeconds();
  const license = await entitledLicense(env, request, now);
  const known = await touchActivation(env.DB, license.id, request.deviceHash, now);
  // A concurrent request from the same Mac may have inserted it first; recheck before refusing.
  if (
    !known &&
    !(await addActivation(env.DB, license, request.deviceHash, now)) &&
    !(await touchActivation(env.DB, license.id, request.deviceHash, now))
  ) {
    throw new ApiError("activation_limit");
  }
  return leaseResponse(env, license, request.deviceHash, now);
}

async function refresh(request: ClientRequest, env: Env): Promise<Response> {
  const now = nowSeconds();
  const license = await entitledLicense(env, request, now);
  if (!(await touchActivation(env.DB, license.id, request.deviceHash, now))) throw new ApiError("not_activated");
  return leaseResponse(env, license, request.deviceHash, now);
}

async function deactivate(request: ClientRequest, env: Env): Promise<Response> {
  const license = await findLicense(env.DB, request.product, request.key);
  if (!license) throw new ApiError("invalid_key");
  await removeActivation(env.DB, license.id, request.deviceHash);
  return json({ ok: true });
}

async function leaseResponse(env: Env, license: LicenseRow, deviceHash: string, now: number): Promise<Response> {
  const key = await signingKey(env);
  const payload: LeasePayload = {
    v: 1,
    kid: key.kid,
    licenseId: license.id,
    product: license.product_id,
    deviceHash,
    validUntil: license.valid_until,
    updatesUntil: license.updates_until,
    issuedAt: now,
    ...leaseWindow(now, license.valid_until),
  };
  return json({ lease: await signLease(payload, key) });
}

// MARK: - Provider webhooks

function providerAdapter(env: Env, name: string): ProviderAdapter | null {
  if (name === "polar" && env.POLAR_WEBHOOK_SECRET) return new PolarAdapter(env.POLAR_WEBHOOK_SECRET);
  return null;
}

async function receiveWebhook(request: Request, env: Env, name: string): Promise<Response> {
  const adapter = providerAdapter(env, name);
  if (!adapter) throw new ApiError("not_found");
  let verified;
  try {
    verified = await adapter.verifyWebhook(request);
  } catch {
    throw new ApiError("bad_request");
  }
  if (!verified) throw new ApiError("unauthorized");

  const seen = await env.DB.prepare("SELECT 1 FROM webhook_events WHERE provider = ? AND event_id = ?")
    .bind(adapter.name, verified.eventId)
    .first();
  if (seen) return json({ ok: true });

  let outcome;
  try {
    outcome = await applyEvent(env.DB, adapter.name, verified.event, nowSeconds());
  } catch (error) {
    // Non-2xx makes the provider retry, e.g. after the missing Offer is added.
    if (error instanceof UnknownOfferError) return json({ error: "unknown_offer" }, 422);
    if (error instanceof NotYetKnownError) return json({ error: "not_yet_known" }, 409);
    throw error;
  }
  const mailer = keyMailer(env);
  if (outcome.customerId && mailer) {
    try {
      await deliverPendingKeys(env.DB, mailer, outcome.customerId, nowSeconds());
    } catch {
      // The License exists; the provider's retry sends only the keys still unsent.
      return json({ error: "email_failed" }, 502);
    }
  }
  await env.DB.prepare("INSERT OR IGNORE INTO webhook_events (provider, event_id, received_at) VALUES (?, ?, ?)")
    .bind(adapter.name, verified.eventId, nowSeconds())
    .run();
  return json({ ok: true });
}

// MARK: - Key email

/** Test compositions may replace the mailer. */
export const mailerOverride: { current: KeyMailer | null } = { current: null };

function keyMailer(env: Env): KeyMailer | null {
  if (mailerOverride.current) return mailerOverride.current;
  if (!env.RESEND_API_KEY || !env.EMAIL_FROM) return null;
  return new ResendMailer(env.RESEND_API_KEY, env.EMAIL_FROM);
}

const RESEND_INTERVAL = 10 * 60;

/**
 * Emails every active key on file to the purchase address, and only that address. The response
 * is identical whether or not the address bought, and each address can trigger it once per interval.
 */
async function resendKey(body: Record<string, unknown>, env: Env): Promise<Response> {
  const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
  if (!/^[^\s@]+@[^\s@]+$/.test(email) || email.length > 254) throw new ApiError("bad_request");
  const now = nowSeconds();
  const mailer = keyMailer(env);
  const claimed = await env.DB.prepare(
    "UPDATE customers SET last_resend_at = ? WHERE email = ? AND (last_resend_at IS NULL OR last_resend_at <= ?)",
  )
    .bind(now, email, now - RESEND_INTERVAL)
    .run();
  if (mailer && claimed.meta.changes > 0) {
    const { results } = await env.DB.prepare(
      `SELECT l.license_key AS key, p.name AS productName
       FROM licenses l JOIN products p ON p.id = l.product_id JOIN customers c ON c.id = l.customer_id
       WHERE c.email = ? AND l.status = 'active' ORDER BY l.created_at`,
    )
      .bind(email)
      .all<{ key: string; productName: string }>();
    if (results.length > 0) {
      try {
        await mailer.sendKeys(email, results);
      } catch {
        // Same response either way, so the form never reveals whether an address bought.
      }
    }
  }
  return json({ ok: true }, 202);
}

// MARK: - Admin endpoints

async function requireAdmin(request: Request, env: Env): Promise<void> {
  const header = request.headers.get("authorization") ?? "";
  const expected = `Bearer ${env.ADMIN_TOKEN}`;
  if (!env.ADMIN_TOKEN || !(await constantTimeEqual(header, expected))) throw new ApiError("unauthorized");
}

async function constantTimeEqual(a: string, b: string): Promise<boolean> {
  const [da, db] = await Promise.all(
    [a, b].map(async (value) => new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)))),
  );
  let diff = 0;
  for (let i = 0; i < da.length; i++) diff |= da[i] ^ db[i];
  return diff === 0;
}

const optionalTime = (value: unknown): number | null => {
  if (value === undefined || value === null) return null;
  // Unix seconds only: rejects milliseconds, which would silently mean the year 50,000+.
  if (typeof value !== "number" || !Number.isInteger(value) || value < 0 || value > MAX_UNIX_SECONDS) throw new ApiError("bad_request");
  return value;
};

async function adminIssue(body: Record<string, unknown>, env: Env): Promise<Response> {
  if (typeof body.product !== "string") throw new ApiError("bad_request");
  const maxActivations = body.maxActivations ?? undefined;
  if (maxActivations !== undefined && (typeof maxActivations !== "number" || !Number.isInteger(maxActivations) || maxActivations < 1)) {
    throw new ApiError("bad_request");
  }
  if ((await productKeyPrefix(env.DB, body.product)) === null) throw new ApiError("bad_request");
  const license = await issueLicense(
    env.DB,
    {
      product: body.product,
      validUntil: optionalTime(body.validUntil),
      updatesUntil: optionalTime(body.updatesUntil),
      maxActivations,
    },
    nowSeconds(),
  );
  return json({ licenseId: license.id, key: license.license_key }, 201);
}

async function adminUpsertOffer(body: Record<string, unknown>, env: Env): Promise<Response> {
  const { id, product, provider, providerRef, kind } = body;
  const updatesDays = body.updatesDays ?? null;
  const maxActivations = body.maxActivations ?? 3;
  const active = body.active ?? true;
  const isString = (value: unknown): value is string => typeof value === "string" && value.length > 0 && value.length <= 128;
  if (!isString(id) || !isString(product) || !isString(provider) || !isString(providerRef)) throw new ApiError("bad_request");
  if (kind !== "perpetual" && kind !== "update_window" && kind !== "subscription") throw new ApiError("bad_request");
  if (kind === "update_window" && (typeof updatesDays !== "number" || !Number.isInteger(updatesDays) || updatesDays < 1)) throw new ApiError("bad_request");
  if (typeof maxActivations !== "number" || !Number.isInteger(maxActivations) || maxActivations < 1) throw new ApiError("bad_request");
  if (typeof active !== "boolean") throw new ApiError("bad_request");
  if ((await productKeyPrefix(env.DB, product)) === null) throw new ApiError("bad_request");
  await env.DB.prepare(
    `INSERT INTO offers (id, product_id, provider, provider_ref, kind, updates_days, max_activations, active, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT (id) DO UPDATE SET product_id = excluded.product_id, provider = excluded.provider,
       provider_ref = excluded.provider_ref, kind = excluded.kind, updates_days = excluded.updates_days,
       max_activations = excluded.max_activations, active = excluded.active`,
  )
    .bind(id, product, provider, providerRef, kind, kind === "update_window" ? updatesDays : null, maxActivations, active ? 1 : 0, nowSeconds())
    .run();
  return json({ ok: true });
}

async function adminLicensesByEmail(body: Record<string, unknown>, env: Env): Promise<Response> {
  if (typeof body.email !== "string" || !body.email.includes("@")) throw new ApiError("bad_request");
  const { results } = await env.DB.prepare(
    `SELECT l.product_id AS product, l.license_key AS key, l.status, l.valid_until AS validUntil, l.updates_until AS updatesUntil
     FROM licenses l JOIN customers c ON c.id = l.customer_id WHERE c.email = ? ORDER BY l.created_at`,
  )
    .bind(body.email.toLowerCase())
    .all();
  return json({ licenses: results });
}

async function adminLicense(body: Record<string, unknown>, env: Env): Promise<LicenseRow> {
  if (typeof body.product !== "string" || typeof body.key !== "string") throw new ApiError("bad_request");
  const prefix = await productKeyPrefix(env.DB, body.product);
  if (prefix === null) throw new ApiError("not_found");
  const license = await findLicense(env.DB, body.product, normalizeLicenseKey(body.key, prefix));
  if (!license) throw new ApiError("not_found");
  return license;
}

async function adminLookup(body: Record<string, unknown>, env: Env): Promise<Response> {
  const license = await adminLicense(body, env);
  return json({
    licenseId: license.id,
    status: license.status,
    validUntil: license.valid_until,
    updatesUntil: license.updates_until,
    maxActivations: license.max_activations,
    activations: await activationCount(env.DB, license.id),
  });
}

async function adminRevoke(body: Record<string, unknown>, env: Env): Promise<Response> {
  const license = await adminLicense(body, env);
  await revokeLicense(env.DB, license.id, "admin", nowSeconds());
  return json({ ok: true });
}

async function adminReset(body: Record<string, unknown>, env: Env): Promise<Response> {
  const license = await adminLicense(body, env);
  await resetActivations(env.DB, license.id, nowSeconds());
  return json({ ok: true });
}

async function readJson(request: Request): Promise<Record<string, unknown>> {
  try {
    const body: unknown = await request.json();
    if (body && typeof body === "object" && !Array.isArray(body)) return body as Record<string, unknown>;
  } catch {
    // Fall through to bad_request.
  }
  throw new ApiError("bad_request");
}
