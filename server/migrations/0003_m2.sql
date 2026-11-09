-- M2: place details, device tokens, settings, push bookkeeping.
ALTER TABLE places ADD COLUMN kind TEXT NOT NULL DEFAULT 'saved';
ALTER TABLE places ADD COLUMN notify INTEGER NOT NULL DEFAULT 0;
ALTER TABLE places ADD COLUMN position INTEGER NOT NULL DEFAULT 0;
-- Current-location places: polled while requested within the last 24 h.
ALTER TABLE places ADD COLUMN last_requested_at INTEGER;
UPDATE places SET position = id;

CREATE TABLE devices (
    id           INTEGER PRIMARY KEY,
    name         TEXT    NOT NULL,
    token_hash   TEXT    NOT NULL UNIQUE,
    subject      TEXT,
    created_at   INTEGER NOT NULL,
    last_used_at INTEGER
);

-- One-time codes of the device sign-in (PKCE), 5 minutes.
CREATE TABLE device_codes (
    code_hash  TEXT    PRIMARY KEY,
    challenge  TEXT    NOT NULL,
    name       TEXT    NOT NULL,
    subject    TEXT,
    expires_at INTEGER NOT NULL
);

CREATE TABLE settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- Push: what was already announced, per place.
CREATE TABLE push_sent (
    place_id INTEGER NOT NULL REFERENCES places (id) ON DELETE CASCADE,
    key      TEXT    NOT NULL,
    sent_at  INTEGER NOT NULL,
    PRIMARY KEY (place_id, key)
);
