-- Latest known state of each provider subscription, recorded even before its License exists,
-- so events that arrive before the paid order (period updates, an ended subscription) still apply
-- when the License is minted.
CREATE TABLE subscriptions (
  provider TEXT NOT NULL,
  ref TEXT NOT NULL,
  current_period_end INTEGER,
  ended_at INTEGER,
  PRIMARY KEY (provider, ref)
);
