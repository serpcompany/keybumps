import { env, exports } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { fromBase64url, verifyLease } from "../src/lease";
import { DAY } from "../src/policy";

const device = (n: number) => n.toString(16).padStart(64, "0");
const publicKey = () => fromBase64url(env.TEST_PUBLIC_KEY);

async function post(path: string, body: unknown, headers: Record<string, string> = {}) {
  const response = await exports.default.fetch(`https://licensing.test${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
  return { status: response.status, body: (await response.json()) as Record<string, any> };
}

const admin = (path: string, body: unknown) => post(path, body, { authorization: "Bearer test-admin-token" });

async function newLicense(fields: Record<string, unknown> = {}) {
  const { status, body } = await admin("/admin/licenses", { product: "keybumps", ...fields });
  expect(status).toBe(201);
  return body.key as string;
}

const activate = (key: string, n: number) => post("/v1/activate", { product: "keybumps", key, deviceHash: device(n) });
const refresh = (key: string, n: number) => post("/v1/refresh", { product: "keybumps", key, deviceHash: device(n) });

describe("activation", () => {
  let key: string;
  beforeEach(async () => {
    key = await newLicense();
  });

  it("returns a Lease signed for this device and product", async () => {
    const { status, body } = await activate(key, 1);
    expect(status).toBe(200);
    const lease = await verifyLease(body.lease, publicKey());
    expect(lease).toMatchObject({ v: 1, kid: "test-1", product: "keybumps", deviceHash: device(1), validUntil: null });
    expect(lease!.expiresAt - lease!.issuedAt).toBe(45 * DAY);
    expect(lease!.refreshAfter - lease!.issuedAt).toBe(7 * DAY);
  });

  it("rejects a tampered Lease", async () => {
    const { body } = await activate(key, 1);
    const [payload, signature] = (body.lease as string).split(".");
    const forged = `${payload.slice(0, -2)}AA.${signature}`;
    expect(await verifyLease(forged, publicKey())).toBeNull();
  });

  it("accepts a key typed in lowercase", async () => {
    expect((await activate(key.toLowerCase(), 1)).status).toBe(200);
  });

  it("does not use another slot when the same Mac activates again", async () => {
    for (const n of [1, 1, 2, 3]) expect((await activate(key, n)).status).toBe(200);
    expect(await activate(key, 4)).toEqual({ status: 409, body: { error: "activation_limit" } });
  });

  it("frees a slot on deactivate", async () => {
    for (const n of [1, 2, 3]) await activate(key, n);
    expect((await post("/v1/deactivate", { product: "keybumps", key, deviceHash: device(2) })).status).toBe(200);
    expect((await activate(key, 4)).status).toBe(200);
  });

  it("rejects unknown keys and malformed requests", async () => {
    expect(await activate("KB-0000-0000-0000-0000", 1)).toEqual({ status: 404, body: { error: "invalid_key" } });
    expect((await post("/v1/activate", { product: "keybumps", key, deviceHash: "nothex" })).status).toBe(400);
    expect((await post("/v1/activate", { product: "other", key, deviceHash: device(1) })).body).toEqual({ error: "invalid_key" });
  });
});

describe("refresh", () => {
  it("renews an activated Mac and rejects one that isn't", async () => {
    const key = await newLicense();
    await activate(key, 1);
    expect((await refresh(key, 1)).status).toBe(200);
    expect(await refresh(key, 2)).toEqual({ status: 403, body: { error: "not_activated" } });
  });

  it("returns revoked after the License is revoked", async () => {
    const key = await newLicense();
    await activate(key, 1);
    await admin("/admin/licenses/revoke", { product: "keybumps", key });
    expect(await refresh(key, 1)).toEqual({ status: 403, body: { error: "revoked" } });
  });

  it("returns not_activated after activations are reset", async () => {
    const key = await newLicense();
    await activate(key, 1);
    await admin("/admin/licenses/reset-activations", { product: "keybumps", key });
    expect((await refresh(key, 1)).body).toEqual({ error: "not_activated" });
    expect((await admin("/admin/licenses/lookup", { product: "keybumps", key })).body.activations).toBe(0);
  });
});

describe("subscriptions", () => {
  const now = () => Math.floor(Date.now() / 1000);

  it("caps Lease expiry at validUntil plus grace", async () => {
    const validUntil = now() + 3 * DAY;
    const key = await newLicense({ validUntil });
    const lease = await verifyLease((await activate(key, 1)).body.lease, publicKey());
    expect(lease).toMatchObject({ validUntil, refreshAfter: validUntil, expiresAt: validUntil + 7 * DAY });
  });

  it("stops issuing Leases after the grace period", async () => {
    const key = await newLicense({ validUntil: now() - 8 * DAY });
    expect(await activate(key, 1)).toEqual({ status: 403, body: { error: "expired" } });
  });

  it("carries updatesUntil into the Lease", async () => {
    const key = await newLicense({ updatesUntil: 1_900_000_000 });
    expect((await verifyLease((await activate(key, 1)).body.lease, publicKey()))!.updatesUntil).toBe(1_900_000_000);
  });
});

describe("admin", () => {
  it("requires the admin token", async () => {
    expect((await post("/admin/licenses", { product: "keybumps" })).status).toBe(401);
    expect((await post("/admin/licenses", { product: "keybumps" }, { authorization: "Bearer wrong" })).status).toBe(401);
  });

  it("rejects unknown products and bad activation limits", async () => {
    expect((await admin("/admin/licenses", { product: "nope" })).status).toBe(400);
    expect((await admin("/admin/licenses", { product: "keybumps", maxActivations: 0 })).status).toBe(400);
  });

  it("honors a custom activation limit", async () => {
    const key = await newLicense({ maxActivations: 1 });
    expect((await activate(key, 1)).status).toBe(200);
    expect((await activate(key, 2)).status).toBe(409);
  });
});

it("returns not_found for unknown routes and methods", async () => {
  expect((await post("/nope", {})).status).toBe(404);
  const response = await exports.default.fetch("https://licensing.test/v1/activate");
  expect(response.status).toBe(404);
});
