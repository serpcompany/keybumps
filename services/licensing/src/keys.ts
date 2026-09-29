// License Keys: `<PREFIX>-XXXX-XXXX-XXXX-XXXX` using Crockford base32 (no I, L, O, U),
// 80 random bits.

const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

export function generateLicenseKey(prefix: string): string {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  const chars = Array.from(bytes, (byte) => ALPHABET[byte & 31]).join("");
  return [prefix, ...(chars.match(/.{4}/g) ?? [])].join("-");
}

/**
 * Accepts keys typed in lowercase, with stray spaces, or with Crockford look-alikes
 * (I/L for 1, O for 0) after the product prefix.
 */
export function normalizeLicenseKey(input: string, prefix: string): string {
  const upper = input.toUpperCase().replace(/\s+/g, "");
  const body = upper.startsWith(`${prefix}-`) ? upper.slice(prefix.length + 1) : upper;
  return `${prefix}-${body.replace(/[IL]/g, "1").replace(/O/g, "0")}`;
}
