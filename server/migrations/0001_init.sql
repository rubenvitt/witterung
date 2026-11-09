-- Browser sessions (single user). The raw session ID only lives in the
-- cookie; the table stores its HMAC.
CREATE TABLE sessions (
    id_hash      TEXT PRIMARY KEY,
    subject      TEXT,
    name         TEXT,
    email        TEXT,
    created_at   INTEGER NOT NULL,
    expires_at   INTEGER NOT NULL,
    last_seen_at INTEGER NOT NULL
);
CREATE INDEX sessions_expires ON sessions (expires_at);
