-- Several Offers may share one provider product (pricing variants chosen by checkout
-- metadata), so (provider, provider_ref) is indexed rather than unique.
--
-- The rows move through a scratch table and back into a table named `offers`, so existing
-- orders' foreign keys still resolve when the transaction commits.
PRAGMA defer_foreign_keys = true;

CREATE TABLE offers_copy AS SELECT * FROM offers;
DROP TABLE offers;
CREATE TABLE offers (
  id TEXT PRIMARY KEY,
  product_id TEXT NOT NULL REFERENCES products(id),
  provider TEXT NOT NULL,
  provider_ref TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('perpetual', 'update_window', 'subscription')),
  updates_days INTEGER,
  max_activations INTEGER NOT NULL DEFAULT 3,
  active INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL
);
INSERT INTO offers SELECT * FROM offers_copy;
DROP TABLE offers_copy;
CREATE INDEX offers_provider_ref ON offers (provider, provider_ref);
CREATE INDEX licenses_subscription_ref ON licenses (subscription_ref);
