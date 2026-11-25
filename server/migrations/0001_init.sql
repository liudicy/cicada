-- Devices: a Mac (later a port) is its Ed25519 public key; there are no accounts.
CREATE TABLE devices (
  id TEXT PRIMARY KEY,            -- hex of the first 16 bytes of sha256(pubkey)
  pubkey BLOB NOT NULL,
  platform TEXT,
  app_version TEXT,
  created_at INTEGER NOT NULL,
  banned_at INTEGER
);

-- Shares: metadata only; the share document itself is in R2 under shares/<id>.json.
CREATE TABLE shares (
  id TEXT PRIMARY KEY,            -- 128 random bits, base64url
  device_id TEXT NOT NULL REFERENCES devices(id),
  token_hash BLOB NOT NULL,       -- sha256 of the manage token; the token itself is only on the Mac
  idem_key TEXT,                  -- the client's Idempotency-Key: a retried create returns the same share
  mode TEXT NOT NULL,             -- open | password
  scope TEXT NOT NULL,            -- notes | full
  title TEXT NOT NULL,
  og_desc TEXT,
  langs TEXT,
  duration INTEGER,
  size INTEGER NOT NULL,
  pw_salt BLOB, pw_iter INTEGER, pw_hash BLOB,  -- sha256 of the PBKDF2 verifier the browser sends
  check_max TEXT NOT NULL,        -- the highest Jev score per question, never the text
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  revoked_at INTEGER,
  revoked_by TEXT,                -- owner | admin | expired
  purged_at INTEGER               -- the R2 object is gone
);
-- Only live shares: the same meeting shared again after its link was turned off is a new share.
CREATE UNIQUE INDEX shares_idem ON shares(device_id, idem_key) WHERE revoked_at IS NULL;
CREATE INDEX shares_device ON shares(device_id, revoked_at);
CREATE INDEX shares_expiry ON shares(expires_at, purged_at);
