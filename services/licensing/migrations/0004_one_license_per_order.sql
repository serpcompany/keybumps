-- An order mints at most one License, so a retried or concurrent fulfillment can't mint twice.
CREATE UNIQUE INDEX licenses_order ON licenses (order_id) WHERE order_id IS NOT NULL;
