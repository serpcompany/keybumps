-- Failed key-email attempts, so the retry cron skips keys that keep failing instead of starving others.
ALTER TABLE licenses ADD COLUMN email_attempts INTEGER NOT NULL DEFAULT 0;
