#!/usr/bin/env bash
# Provisions and deploys the production licensing service (live Polar). Run it yourself;
# it creates Cloudflare resources and production secrets. Safe to re-run: finished steps are skipped.
#
#   scripts/provision-production.sh <live-polar-product-id>
#
# Afterwards it prints the remaining owner steps (Polar webhook, Resend, website var).
set -euo pipefail
cd "$(dirname "$0")/.."

product_id="${1:?usage: scripts/provision-production.sh <live-polar-product-id>}"
secrets_file="production.secrets.json"
# The top level is production; `--env ""` targets it explicitly.
wrangler() { npx wrangler "$@"; }

placeholder="00000000-0000-0000-0000-000000000000"
if grep -q "$placeholder" wrangler.toml; then
  echo "Creating D1 database keybumps-licensing..."
  database_id="$(wrangler d1 create keybumps-licensing 2>&1 | sed -n 's/.*database_id = "\([0-9a-f-]*\)".*/\1/p' | head -1)"
  [[ -n "$database_id" ]] || { echo "Could not read the new database_id." >&2; exit 1; }
  # Only the first (top-level) placeholder is production's.
  perl -0pi -e "s/$placeholder/$database_id/" wrangler.toml
  echo "Wrote database_id to wrangler.toml; commit it."
fi

wrangler d1 migrations apply keybumps-licensing --remote

if [[ ! -f "$secrets_file" ]]; then
  echo "Generating the production signing key and admin token..."
  umask 077
  # Never leave the private key on disk, even if a later step fails.
  trap 'rm -f prod-1.signing-key.json' EXIT
  node scripts/generate-signing-key.mjs prod-1 >/dev/null
  wrangler secret put LEASE_SIGNING_KEY --env "" < prod-1.signing-key.json
  node -e '
    const fs = require("fs"), crypto = require("crypto");
    const x = JSON.parse(fs.readFileSync("prod-1.signing-key.json", "utf8")).jwk.x;
    fs.writeFileSync(process.argv[1], JSON.stringify({
      adminToken: crypto.randomBytes(32).toString("base64url"),
      signingKid: "prod-1",
      signingPublicKeyBase64: Buffer.from(x, "base64url").toString("base64"),
    }, null, 2), { mode: 0o600 });
  ' "$secrets_file"
  node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).adminToken)' "$secrets_file" \
    | wrangler secret put ADMIN_TOKEN --env ""
  rm prod-1.signing-key.json
  echo "Saved the admin token and public key to $secrets_file (git-ignored). Back it up in your password manager."
fi

wrangler deploy --env ""

echo "Registering the launch Offer (\$49 lifetime, 1 Mac)..."
node -e '
  const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  fetch("https://licensing.keybumps.app/admin/offers", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${s.adminToken}` },
    body: JSON.stringify({ id: "keybumps-lifetime", product: "keybumps", provider: "polar", providerRef: process.argv[2], kind: "perpetual", maxActivations: 1 }),
  }).then(async (r) => { console.log("Offer:", r.status, await r.text()); if (!r.ok) process.exit(1); });
' "$secrets_file" "$product_id"

cat <<'NEXT'

Production licensing is deployed at https://licensing.keybumps.app. Remaining owner steps,
in this order so no paid order arrives before keys can be emailed:
  1. Resend: verify keybumps.app as a sending domain, create an API key, then run:
       npx wrangler secret put RESEND_API_KEY --env ""
  2. Polar (live) > Settings > Webhooks > Add Endpoint:
       URL https://licensing.keybumps.app/webhooks/polar, format Raw, API version 2026-04,
       events order.paid, order.refunded, refund.created, subscription.active, .canceled,
       .cycled, .revoked, .uncanceled, .updated. Then copy its secret and run:
       npx wrangler secret put POLAR_WEBHOOK_SECRET --env ""
  3. Website: set LICENSING_API_URL = "https://licensing.keybumps.app" and deploy the site.
NEXT
