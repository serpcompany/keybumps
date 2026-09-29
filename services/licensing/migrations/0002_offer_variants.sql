-- Several Offers may share one provider product (pricing variants chosen by checkout
-- metadata), so (provider, provider_ref) is indexed rather than unique.
PRAGMA defer_foreign_keys = true;

CREATE TABLE offers_new (
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
INSERT INTO offers_new SELECT * FROM offers;
DROP TABLE offers;
ALTER TABLE offers_new RENAME TO offers;
CREATE INDEX offers_provider_ref ON offers (provider, provider_ref);
CREATE INDEX licenses_subscription_ref ON licenses (subscription_ref);
