// Generates an Ed25519 Lease signing key (docs/adr/0001-licensing.md §6).
//
//   npm run generate-signing-key -- <kid>
//
// Writes <kid>.signing-key.json (git-ignored, mode 600) holding the LEASE_SIGNING_KEY secret
// value, and prints only the public key for the app's Info.plist. Load the secret with
// `wrangler secret put LEASE_SIGNING_KEY < <kid>.signing-key.json`, then delete the file.
import { generateKeyPairSync } from "node:crypto";
import { writeFileSync } from "node:fs";

const kid = process.argv[2];
if (!kid || !/^[a-z0-9-]{1,32}$/.test(kid)) {
  console.error("usage: npm run generate-signing-key -- <kid>   (lowercase letters, digits, dashes)");
  process.exit(1);
}
const { privateKey, publicKey } = generateKeyPairSync("ed25519");
const file = `${kid}.signing-key.json`;
writeFileSync(file, JSON.stringify({ kid, jwk: privateKey.export({ format: "jwk" }) }), { mode: 0o600, flag: "wx" });
const raw = Buffer.from(publicKey.export({ format: "jwk" }).x, "base64url").toString("base64");
console.log(`Wrote ${file} (secret; never commit).`);
console.log(`Public key for kid "${kid}" (base64, 32 bytes): ${raw}`);
