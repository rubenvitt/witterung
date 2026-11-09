-- M1: places, upstream quotas, poll state, latest normalized data per source.
CREATE TABLE places (
    id         INTEGER PRIMARY KEY,
    name       TEXT    NOT NULL,
    lat        REAL    NOT NULL,
    lon        REAL    NOT NULL,
    created_at INTEGER NOT NULL
);

-- Weighted calls per upstream and period ('2026-11-09' or '2026-11', UTC).
CREATE TABLE quota_usage (
    provider TEXT NOT NULL,
    period   TEXT NOT NULL,
    used     REAL NOT NULL,
    PRIMARY KEY (provider, period)
);

-- Persisted so a restart (every deploy) does not refetch everything.
CREATE TABLE fetch_state (
    place_id        INTEGER NOT NULL REFERENCES places (id) ON DELETE CASCADE,
    provider        TEXT    NOT NULL,
    last_attempt_at INTEGER,
    last_success_at INTEGER,
    failures        INTEGER NOT NULL DEFAULT 0,
    error           TEXT,
    PRIMARY KEY (place_id, provider)
);

-- `data` is the JSON of `sources::SourceData`.
CREATE TABLE snapshots (
    place_id   INTEGER NOT NULL REFERENCES places (id) ON DELETE CASCADE,
    source     TEXT    NOT NULL,
    fetched_at INTEGER NOT NULL,
    data       TEXT    NOT NULL,
    PRIMARY KEY (place_id, source)
);
