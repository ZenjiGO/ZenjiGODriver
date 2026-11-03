-- Ride lifecycle hardening: re-dispatch tracking and admin attention flags.
-- (The API also self-applies these on boot via ensureLifecycleSchema(), so this file is idempotent documentation.)
ALTER TABLE rides
  ADD COLUMN IF NOT EXISTS searching_since DATETIME NULL AFTER requested_at,
  ADD COLUMN IF NOT EXISTS redispatch_count TINYINT UNSIGNED NOT NULL DEFAULT 0 AFTER searching_since,
  ADD COLUMN IF NOT EXISTS needs_attention TINYINT(1) NOT NULL DEFAULT 0 AFTER redispatch_count,
  ADD COLUMN IF NOT EXISTS attention_reason VARCHAR(255) NULL AFTER needs_attention;

CREATE INDEX idx_ride_attention ON rides(needs_attention,status);
