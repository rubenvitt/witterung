-- MCP: built-in OAuth 2.1 authorization server for /mcp (claude.ai connectors).

-- Dynamically registered public clients (RFC 7591).
CREATE TABLE oauth_clients (
    id            TEXT    PRIMARY KEY,
    name          TEXT    NOT NULL,
    redirect_uris TEXT    NOT NULL, -- JSON array
    created_at    INTEGER NOT NULL,
    last_used_at  INTEGER
);

-- Single-use authorization codes, 5 minutes; kept after use so a replay
-- can revoke what was issued for them.
CREATE TABLE oauth_codes (
    code_hash      TEXT    PRIMARY KEY,
    client_id      TEXT    NOT NULL REFERENCES oauth_clients (id) ON DELETE CASCADE,
    redirect_uri   TEXT    NOT NULL,
    code_challenge TEXT    NOT NULL,
    resource       TEXT    NOT NULL,
    scope          TEXT,
    family_id      TEXT    NOT NULL,
    expires_at     INTEGER NOT NULL,
    used_at        INTEGER
);

-- Access (1 h) and refresh tokens (30 days, rotating) of a grant (family).
CREATE TABLE oauth_tokens (
    token_hash TEXT    PRIMARY KEY,
    kind       TEXT    NOT NULL CHECK (kind IN ('access', 'refresh')),
    client_id  TEXT    NOT NULL REFERENCES oauth_clients (id) ON DELETE CASCADE,
    family_id  TEXT    NOT NULL,
    resource   TEXT    NOT NULL,
    scope      TEXT,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    used_at    INTEGER,
    revoked_at INTEGER
);
CREATE INDEX oauth_tokens_family ON oauth_tokens (family_id);
CREATE INDEX oauth_tokens_client ON oauth_tokens (client_id);
