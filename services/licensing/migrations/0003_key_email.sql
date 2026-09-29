-- When each License Key was emailed (NULL until sent), and resend-form throttling.
ALTER TABLE licenses ADD COLUMN key_emailed_at INTEGER;
ALTER TABLE customers ADD COLUMN last_resend_at INTEGER;
CREATE INDEX licenses_customer ON licenses (customer_id);
