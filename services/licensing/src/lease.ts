// Ed25519-signed Leases (docs/adr/0001-licensing.md §6).
//
// Wire format: base64url(JSON payload) + "." + base64url(signature over the first segment's
// ASCII bytes). The app verifies the signature with the public key for `kid`, then decodes
// the payload.

export interface LeasePayload {
  v: 1;
  kid: string;
  licenseId: string;
  product: string;
  deviceHash: string;
  validUntil: number | null;
  updatesUntil: number | null;
  issuedAt: number;
  refreshAfter: number;
  expiresAt: number;
}

export interface SigningKey {
  kid: string;
  key: CryptoKey;
}

/** Parses the `LEASE_SIGNING_KEY` secret: `{"kid": "...", "jwk": {Ed25519 private JWK}}`. */
export async function importSigningKey(secret: string): Promise<SigningKey> {
  const parsed = JSON.parse(secret) as { kid?: unknown; jwk?: JsonWebKey };
  if (typeof parsed.kid !== "string" || parsed.kid.length === 0 || !parsed.jwk) {
    throw new Error("LEASE_SIGNING_KEY is malformed");
  }
  const key = await crypto.subtle.importKey("jwk", parsed.jwk, { name: "Ed25519" }, false, ["sign"]);
  return { kid: parsed.kid, key };
}

export async function signLease(payload: LeasePayload, signingKey: SigningKey): Promise<string> {
  const body = base64url(new TextEncoder().encode(JSON.stringify(payload)));
  const signature = await crypto.subtle.sign("Ed25519", signingKey.key, new TextEncoder().encode(body));
  return `${body}.${base64url(new Uint8Array(signature))}`;
}

/** Verifies a Lease against a raw 32-byte public key. Used by tests; the app has its own verifier. */
export async function verifyLease(lease: string, rawPublicKey: Uint8Array): Promise<LeasePayload | null> {
  const [body, signature, extra] = lease.split(".");
  if (!body || !signature || extra !== undefined) return null;
  const key = await crypto.subtle.importKey("raw", rawPublicKey, { name: "Ed25519" }, false, ["verify"]);
  const valid = await crypto.subtle.verify("Ed25519", key, fromBase64url(signature), new TextEncoder().encode(body));
  if (!valid) return null;
  return JSON.parse(new TextDecoder().decode(fromBase64url(body))) as LeasePayload;
}

export function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function fromBase64url(text: string): Uint8Array {
  const padded = text.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(text.length / 4) * 4, "=");
  const binary = atob(padded);
  return Uint8Array.from(binary, (char) => char.charCodeAt(0));
}
