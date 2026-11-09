//! SQLite: opening, migrations, sessions, places and poll results.

use std::path::Path;

use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;

/// Migrations in order; `PRAGMA user_version` counts the applied ones.
const MIGRATIONS: &[&str] = &[
    include_str!("../migrations/0001_init.sql"),
    include_str!("../migrations/0002_sources.sql"),
    include_str!("../migrations/0003_m2.sql"),
];

/// Opens (and creates) the database and applies pending migrations.
pub fn open(path: &Path) -> anyhow::Result<Connection> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let mut conn = Connection::open(path)?;
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.pragma_update(None, "foreign_keys", "ON")?;
    conn.busy_timeout(std::time::Duration::from_secs(5))?;
    migrate(&mut conn)?;
    Ok(conn)
}

fn migrate(conn: &mut Connection) -> anyhow::Result<()> {
    let applied: usize = conn.pragma_query_value(None, "user_version", |r| r.get(0))?;
    if applied > MIGRATIONS.len() {
        anyhow::bail!(
            "Datenbank hat Schema {applied}, diese Version kennt nur {}",
            MIGRATIONS.len()
        );
    }
    for (i, sql) in MIGRATIONS.iter().enumerate().skip(applied) {
        let tx = conn.transaction()?;
        tx.execute_batch(sql)?;
        tx.pragma_update(None, "user_version", i + 1)?;
        tx.commit()?;
        tracing::info!(version = i + 1, "migration applied");
    }
    Ok(())
}

/// Who a session belongs to (from the ID token; empty for dev auth).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SessionOwner {
    pub subject: Option<String>,
    pub name: Option<String>,
    pub email: Option<String>,
}

#[derive(Debug, Clone)]
pub struct SessionRow {
    pub owner: SessionOwner,
    pub last_seen_at: i64,
}

pub fn insert_session(
    conn: &Connection,
    id_hash: &str,
    owner: &SessionOwner,
    now: i64,
    expires_at: i64,
) -> anyhow::Result<()> {
    conn.execute(
        "INSERT INTO sessions (id_hash, subject, name, email, created_at, expires_at, last_seen_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?5)",
        params![
            id_hash,
            owner.subject,
            owner.name,
            owner.email,
            now,
            expires_at
        ],
    )?;
    Ok(())
}

/// A session that has not expired at `now`.
pub fn find_session(
    conn: &Connection,
    id_hash: &str,
    now: i64,
) -> anyhow::Result<Option<SessionRow>> {
    Ok(conn
        .query_row(
            "SELECT subject, name, email, last_seen_at FROM sessions
             WHERE id_hash = ?1 AND expires_at > ?2",
            params![id_hash, now],
            |row| {
                Ok(SessionRow {
                    owner: SessionOwner {
                        subject: row.get(0)?,
                        name: row.get(1)?,
                        email: row.get(2)?,
                    },
                    last_seen_at: row.get(3)?,
                })
            },
        )
        .optional()?)
}

pub fn extend_session(
    conn: &Connection,
    id_hash: &str,
    now: i64,
    expires_at: i64,
) -> anyhow::Result<()> {
    conn.execute(
        "UPDATE sessions SET last_seen_at = ?2, expires_at = ?3 WHERE id_hash = ?1",
        params![id_hash, now, expires_at],
    )?;
    Ok(())
}

pub fn delete_session(conn: &Connection, id_hash: &str) -> anyhow::Result<()> {
    conn.execute("DELETE FROM sessions WHERE id_hash = ?1", [id_hash])?;
    Ok(())
}

/// Removes expired sessions; returns how many.
pub fn purge_expired_sessions(conn: &Connection, now: i64) -> anyhow::Result<usize> {
    Ok(conn.execute("DELETE FROM sessions WHERE expires_at <= ?1", [now])?)
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Place {
    pub id: i64,
    pub name: String,
    pub lat: f64,
    pub lon: f64,
    /// `saved` or `current` (the device location, snapped to a grid).
    pub kind: String,
    pub notify: bool,
    #[serde(skip)]
    pub last_requested_at: Option<i64>,
}

const PLACE_COLUMNS: &str = "id, name, lat, lon, kind, notify, last_requested_at";

fn place_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<Place> {
    Ok(Place {
        id: r.get(0)?,
        name: r.get(1)?,
        lat: r.get(2)?,
        lon: r.get(3)?,
        kind: r.get(4)?,
        notify: r.get(5)?,
        last_requested_at: r.get(6)?,
    })
}

pub fn insert_place(
    conn: &Connection,
    name: &str,
    lat: f64,
    lon: f64,
    now: i64,
) -> anyhow::Result<Place> {
    conn.execute(
        "INSERT INTO places (name, lat, lon, created_at, kind, position)
         VALUES (?1, ?2, ?3, ?4, 'saved', (SELECT COALESCE(MAX(position), 0) + 1 FROM places))",
        params![name, lat, lon, now],
    )?;
    Ok(find_place(conn, conn.last_insert_rowid())?.expect("just inserted"))
}

/// All places: saved ones in their order, then current-location ones.
pub fn list_places(conn: &Connection) -> anyhow::Result<Vec<Place>> {
    let mut stmt = conn.prepare(&format!(
        "SELECT {PLACE_COLUMNS} FROM places ORDER BY kind = 'current', position, id"
    ))?;
    let rows = stmt.query_map([], place_row)?;
    Ok(rows.collect::<Result<_, _>>()?)
}

pub fn find_place(conn: &Connection, id: i64) -> anyhow::Result<Option<Place>> {
    Ok(conn
        .query_row(
            &format!("SELECT {PLACE_COLUMNS} FROM places WHERE id = ?1"),
            [id],
            place_row,
        )
        .optional()?)
}

#[derive(Debug, Default, serde::Deserialize)]
pub struct PlaceUpdate {
    pub name: Option<String>,
    pub notify: Option<bool>,
    /// New index among the saved places (0 = first).
    pub position: Option<usize>,
}

pub fn update_place(conn: &Connection, id: i64, update: &PlaceUpdate) -> anyhow::Result<bool> {
    let tx = conn.unchecked_transaction()?;
    let changed = tx.execute(
        "UPDATE places SET name = COALESCE(?2, name), notify = COALESCE(?3, notify)
         WHERE id = ?1 AND kind = 'saved'",
        params![id, update.name, update.notify],
    )?;
    if changed == 0 {
        return Ok(false);
    }
    if let Some(pos) = update.position {
        let mut ids: Vec<i64> = list_places(&tx)?
            .into_iter()
            .filter(|p| p.kind == "saved" && p.id != id)
            .map(|p| p.id)
            .collect();
        ids.insert(pos.min(ids.len()), id);
        for (i, pid) in ids.iter().enumerate() {
            tx.execute(
                "UPDATE places SET position = ?2 WHERE id = ?1",
                params![pid, i as i64 + 1],
            )?;
        }
    }
    tx.commit()?;
    Ok(true)
}

pub fn delete_place(conn: &Connection, id: i64) -> anyhow::Result<bool> {
    Ok(conn.execute("DELETE FROM places WHERE id = ?1 AND kind = 'saved'", [id])? > 0)
}

/// The current-location place at the snapped coordinates (created on first
/// use); marks it as requested now.
pub fn current_place(conn: &Connection, lat: f64, lon: f64, now: i64) -> anyhow::Result<Place> {
    let existing: Option<i64> = conn
        .query_row(
            "SELECT id FROM places WHERE kind = 'current' AND abs(lat - ?1) < 1e-6 AND abs(lon - ?2) < 1e-6",
            params![lat, lon],
            |r| r.get(0),
        )
        .optional()?;
    let id = match existing {
        Some(id) => id,
        None => {
            conn.execute(
                "INSERT INTO places (name, lat, lon, created_at, kind) VALUES ('Mein Standort', ?1, ?2, ?3, 'current')",
                params![lat, lon, now],
            )?;
            conn.last_insert_rowid()
        }
    };
    conn.execute(
        "UPDATE places SET last_requested_at = ?2 WHERE id = ?1",
        params![id, now],
    )?;
    Ok(find_place(conn, id)?.expect("exists"))
}

/// Forgets current-location places not requested since `before`.
pub fn purge_current_places(conn: &Connection, before: i64) -> anyhow::Result<usize> {
    Ok(conn.execute(
        "DELETE FROM places WHERE kind = 'current' AND COALESCE(last_requested_at, 0) < ?1",
        [before],
    )?)
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Device {
    pub id: i64,
    pub name: String,
    pub created_at: i64,
    pub last_used_at: Option<i64>,
}

pub fn insert_device_code(
    conn: &Connection,
    code_hash: &str,
    challenge: &str,
    name: &str,
    subject: Option<&str>,
    expires_at: i64,
) -> anyhow::Result<()> {
    conn.execute(
        "DELETE FROM device_codes WHERE expires_at <= ?1",
        [expires_at - 5 * 60_000],
    )?;
    conn.execute(
        "INSERT INTO device_codes (code_hash, challenge, name, subject, expires_at) VALUES (?1, ?2, ?3, ?4, ?5)",
        params![code_hash, challenge, name, subject, expires_at],
    )?;
    Ok(())
}

/// Takes a code (single use): `(challenge, name, subject)` if valid at `now`.
pub fn take_device_code(
    conn: &Connection,
    code_hash: &str,
    now: i64,
) -> anyhow::Result<Option<(String, String, Option<String>)>> {
    let row = conn
        .query_row(
            "SELECT challenge, name, subject, expires_at FROM device_codes WHERE code_hash = ?1",
            [code_hash],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get::<_, i64>(3)?)),
        )
        .optional()?;
    conn.execute("DELETE FROM device_codes WHERE code_hash = ?1", [code_hash])?;
    Ok(row.filter(|r| r.3 > now).map(|(c, n, s, _)| (c, n, s)))
}

pub fn insert_device(
    conn: &Connection,
    name: &str,
    token_hash: &str,
    subject: Option<&str>,
    now: i64,
) -> anyhow::Result<i64> {
    conn.execute(
        "INSERT INTO devices (name, token_hash, subject, created_at) VALUES (?1, ?2, ?3, ?4)",
        params![name, token_hash, subject, now],
    )?;
    Ok(conn.last_insert_rowid())
}

/// The device a token hash belongs to; refreshes `last_used_at` at most hourly.
pub fn device_by_token(
    conn: &Connection,
    token_hash: &str,
    now: i64,
) -> anyhow::Result<Option<Device>> {
    let device = conn
        .query_row(
            "SELECT id, name, created_at, last_used_at FROM devices WHERE token_hash = ?1",
            [token_hash],
            |r| {
                Ok(Device {
                    id: r.get(0)?,
                    name: r.get(1)?,
                    created_at: r.get(2)?,
                    last_used_at: r.get(3)?,
                })
            },
        )
        .optional()?;
    if let Some(d) = &device {
        if d.last_used_at.is_none_or(|t| now - t > 3_600_000) {
            conn.execute(
                "UPDATE devices SET last_used_at = ?2 WHERE id = ?1",
                params![d.id, now],
            )?;
        }
    }
    Ok(device)
}

pub fn list_devices(conn: &Connection) -> anyhow::Result<Vec<Device>> {
    let mut stmt =
        conn.prepare("SELECT id, name, created_at, last_used_at FROM devices ORDER BY id")?;
    let rows = stmt.query_map([], |r| {
        Ok(Device {
            id: r.get(0)?,
            name: r.get(1)?,
            created_at: r.get(2)?,
            last_used_at: r.get(3)?,
        })
    })?;
    Ok(rows.collect::<Result<_, _>>()?)
}

pub fn delete_device(conn: &Connection, id: i64) -> anyhow::Result<bool> {
    Ok(conn.execute("DELETE FROM devices WHERE id = ?1", [id])? > 0)
}

pub fn get_setting(conn: &Connection, key: &str) -> anyhow::Result<Option<String>> {
    Ok(conn
        .query_row("SELECT value FROM settings WHERE key = ?1", [key], |r| {
            r.get(0)
        })
        .optional()?)
}

pub fn set_setting(conn: &Connection, key: &str, value: &str) -> anyhow::Result<()> {
    conn.execute(
        "INSERT INTO settings (key, value) VALUES (?1, ?2)
         ON CONFLICT (key) DO UPDATE SET value = excluded.value",
        params![key, value],
    )?;
    Ok(())
}

/// Records a push key for a place; `false` if it was already sent.
pub fn mark_push_sent(
    conn: &Connection,
    place_id: i64,
    key: &str,
    now: i64,
) -> anyhow::Result<bool> {
    Ok(conn.execute(
        "INSERT OR IGNORE INTO push_sent (place_id, key, sent_at) VALUES (?1, ?2, ?3)",
        params![place_id, key, now],
    )? > 0)
}

pub fn unmark_push_sent(conn: &Connection, place_id: i64, key: &str) -> anyhow::Result<()> {
    conn.execute(
        "DELETE FROM push_sent WHERE place_id = ?1 AND key = ?2",
        params![place_id, key],
    )?;
    Ok(())
}

pub fn purge_push_sent(conn: &Connection, before: i64) -> anyhow::Result<()> {
    conn.execute("DELETE FROM push_sent WHERE sent_at < ?1", [before])?;
    Ok(())
}

/// Poll bookkeeping of one provider for one place (times in ms).
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct FetchState {
    pub last_attempt_at: Option<i64>,
    pub last_success_at: Option<i64>,
    pub failures: u32,
    pub error: Option<String>,
}

pub fn fetch_state(conn: &Connection, place_id: i64, provider: &str) -> anyhow::Result<FetchState> {
    Ok(conn
        .query_row(
            "SELECT last_attempt_at, last_success_at, failures, error FROM fetch_state
             WHERE place_id = ?1 AND provider = ?2",
            params![place_id, provider],
            |r| {
                Ok(FetchState {
                    last_attempt_at: r.get(0)?,
                    last_success_at: r.get(1)?,
                    failures: r.get(2)?,
                    error: r.get(3)?,
                })
            },
        )
        .optional()?
        .unwrap_or_default())
}

pub fn save_fetch_state(
    conn: &Connection,
    place_id: i64,
    provider: &str,
    state: &FetchState,
) -> anyhow::Result<()> {
    conn.execute(
        "INSERT INTO fetch_state (place_id, provider, last_attempt_at, last_success_at, failures, error)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)
         ON CONFLICT (place_id, provider) DO UPDATE SET
           last_attempt_at = excluded.last_attempt_at, last_success_at = excluded.last_success_at,
           failures = excluded.failures, error = excluded.error",
        params![
            place_id,
            provider,
            state.last_attempt_at,
            state.last_success_at,
            state.failures,
            state.error
        ],
    )?;
    Ok(())
}

pub fn save_snapshot(
    conn: &Connection,
    place_id: i64,
    source: &str,
    fetched_at: i64,
    data: &str,
) -> anyhow::Result<()> {
    conn.execute(
        "INSERT INTO snapshots (place_id, source, fetched_at, data) VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT (place_id, source) DO UPDATE SET
           fetched_at = excluded.fetched_at, data = excluded.data",
        params![place_id, source, fetched_at, data],
    )?;
    Ok(())
}

/// `(source, fetched_at, data JSON)` of all sources of a place.
pub fn snapshots(conn: &Connection, place_id: i64) -> anyhow::Result<Vec<(String, i64, String)>> {
    let mut stmt = conn.prepare(
        "SELECT source, fetched_at, data FROM snapshots WHERE place_id = ?1 ORDER BY source",
    )?;
    let rows = stmt.query_map([place_id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
    Ok(rows.collect::<Result<_, _>>()?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migrates_once_and_stores_sessions() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("w.db");
        let conn = open(&path).unwrap();
        drop(conn);
        let conn = open(&path).unwrap(); // second open: no re-run
        let owner = SessionOwner {
            subject: Some("s".into()),
            ..Default::default()
        };
        insert_session(&conn, "h", &owner, 100, 200).unwrap();
        assert_eq!(find_session(&conn, "h", 150).unwrap().unwrap().owner, owner);
        assert!(find_session(&conn, "h", 200).unwrap().is_none(), "expired");
        assert_eq!(purge_expired_sessions(&conn, 200).unwrap(), 1);
    }
}
