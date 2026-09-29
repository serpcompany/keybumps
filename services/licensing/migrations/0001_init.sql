-- SERP licensing schema. Provider-specific data is limited to provider + provider_ref.
CREATE TABLE products (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  key_prefix TEXT NOT NULL
);

CREATE TABLE offers (
  id TEXT PRIMARY KEY,
  product_id TEXT NOT NULL REFERENCES products(id),
  provider TEXT NOT NULL,
  provider_ref TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('perpetual', 'update_window', 'subscription')),
  updates_days INTEGER,
  max_activations INTEGER NOT NULL DEFAULT 3,
  active INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL,
  UNIQUE (provider, provider_ref)
);

CREATE TABLE customers (
  id TEXT PRIMARY KEY,
  email TEXT NOT NULL,
  provider TEXT,
  provider_ref TEXT,
  created_at INTEGER NOT NULL,
  UNIQUE (provider, provider_ref)
);
CREATE INDEX customers_email ON customers (email);

CREATE TABLE orders (
  id TEXT PRIMARY KEY,
  provider TEXT NOT NULL,
  provider_ref TEXT NOT NULL,
  customer_id TEXT NOT NULL REFERENCES customers(id),
  offer_id TEXT NOT NULL REFERENCES offers(id),
  status TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  UNIQUE (provider, provider_ref)
);

CREATE TABLE licenses (
  id TEXT PRIMARY KEY,
  product_id TEXT NOT NULL REFERENCES products(id),
  license_key TEXT NOT NULL UNIQUE,
  customer_id TEXT REFERENCES customers(id),
  order_id TEXT REFERENCES orders(id),
  subscription_ref TEXT,
  valid_until INTEGER,
  updates_until INTEGER,
  max_activations INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'revoked')),
  revoked_reason TEXT,
  last_reset_at INTEGER,
  created_at INTEGER NOT NULL,
  revoked_at INTEGER
);

CREATE TABLE activations (
  license_id TEXT NOT NULL REFERENCES licenses(id),
  device_hash TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL,
  PRIMARY KEY (license_id, device_hash)
);

CREATE TABLE webhook_events (
  provider TEXT NOT NULL,
  event_id TEXT NOT NULL,
  received_at INTEGER NOT NULL,
  PRIMARY KEY (provider, event_id)
);

INSERT INTO products (id, name, key_prefix) VALUES ('keybumps', 'Keybumps', 'KB');
