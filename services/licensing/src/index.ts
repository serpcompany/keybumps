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
import { isWithinTerm, leaseWindow } from "./policy";

export interface Env {
  DB: D1Database;
  /** `{"kid": "...", "jwk": {Ed25519 private JWK}}` */
  LEASE_SIGNING_KEY: string;
  ADMIN_TOKEN: string;
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
  switch (pathname) {
    case "/v1/activate":
      return activate(await clientRequest(request, env), env);
    case "/v1/refresh":
      return refresh(await clientRequest(request, env), env);
    case "/v1/deactivate":
      return deactivate(await clientRequest(request, env), env);
    case "/admin/licenses":
      await requireAdmin(request, env);
      return adminIssue(await readJson(request), env);
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
  const deviceHash = body.deviceHash;
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
  if (!known && !(await addActivation(env.DB, license, request.deviceHash, now))) {
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
  if (typeof value !== "number" || !Number.isInteger(value) || value < 0) throw new ApiError("bad_request");
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
