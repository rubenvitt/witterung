-- Live-Aktivitäten über APNs (live.rs).
-- Je Gerät eine Anmeldung: Push-to-Start-Token und der Ort, dem die Aktivität folgt.
CREATE TABLE live_registrations (
    device_id   INTEGER PRIMARY KEY REFERENCES devices (id) ON DELETE CASCADE,
    start_token TEXT,
    -- Token aus einem Debug-Build gelten nur für die Sandbox von APNs.
    sandbox     INTEGER NOT NULL DEFAULT 0,
    place_id    INTEGER REFERENCES places (id) ON DELETE SET NULL,
    -- Wofür zuletzt eine Aktivität gestartet wurde (Regenschauer, Warnung):
    -- dasselbe Ereignis startet nur einmal, auch wenn die Person sie wegwischt.
    start_key   TEXT,
    started_at  INTEGER,
    updated_at  INTEGER NOT NULL
);

-- Laufende Aktivitäten mit ihrem Update-Token (meldet die App).
CREATE TABLE live_activities (
    activity_id TEXT    PRIMARY KEY,
    device_id   INTEGER NOT NULL REFERENCES devices (id) ON DELETE CASCADE,
    place_id    INTEGER REFERENCES places (id) ON DELETE SET NULL,
    token       TEXT    NOT NULL,
    sandbox     INTEGER NOT NULL DEFAULT 0,
    -- Zuletzt gesendeter Inhalt (JSON), damit nur Änderungen rausgehen.
    state       TEXT,
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER NOT NULL
);
CREATE INDEX live_activities_device ON live_activities (device_id);
