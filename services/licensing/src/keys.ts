// License Keys: `<PREFIX>-XXXX-XXXX-XXXX-XXXX` using Crockford base32 (no I, L, O, U),
// 80 random bits.

const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const KEY_LENGTH = 16;

export function generateLicenseKey(prefix: string): string {
  const bytes = crypto.getRandomValues(new Uint8Array(KEY_LENGTH));
  const chars = Array.from(bytes, (byte) => ALPHABET[byte & 31]).join("");
  return [prefix, ...(chars.match(/.{4}/g) ?? [])].join("-");
}

/**
 * Accepts keys typed in lowercase, with stray spaces, or with Crockford look-alikes
 * (I/L for 1, O for 0) after the product prefix.
 */
export function normalizeLicenseKey(input: string, prefix: string): string {
  const upper = input.toUpperCase().replace(/[\s-]+/g, "");
  // Strip the prefix only when the key is full length, so a prefix-less body that happens
  // to start with the prefix letters is kept intact.
  const hasPrefix = upper.startsWith(prefix) && upper.length === prefix.length + KEY_LENGTH;
  const body = (hasPrefix ? upper.slice(prefix.length) : upper).replace(/[IL]/g, "1").replace(/O/g, "0");
  return [prefix, ...(body.match(/.{1,4}/g) ?? [])].join("-");
}
