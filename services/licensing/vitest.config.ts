import { generateKeyPairSync } from "node:crypto";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig(async () => {
  // A throwaway signing key per test run; its raw public key is handed to the tests.
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const jwk = privateKey.export({ format: "jwk" });
  const rawPublicKey = publicKey.export({ format: "jwk" }).x;

  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.toml" },
        miniflare: {
          bindings: {
            TEST_MIGRATIONS: await readD1Migrations("./migrations"),
            TEST_PUBLIC_KEY: rawPublicKey,
            LEASE_SIGNING_KEY: JSON.stringify({ kid: "test-1", jwk }),
            ADMIN_TOKEN: "test-admin-token",
          },
        },
      }),
    ],
    test: { setupFiles: ["./test/apply-migrations.ts"] },
  };
});
