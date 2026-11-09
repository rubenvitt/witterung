//! SQLite: opening, migrations, sessions, places and poll results.

use std::path::Path;

use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;

/// Migrations in order; `PRAGMA user_version` counts the applied ones.
const MIGRATIONS: &[&str] = &[
    include_str!("../migrations/0001_init.sql"),
    include_str!("../migrations/0002_sources.sql"),
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
}

pub fn insert_place(
    conn: &Connection,
    name: &str,
    lat: f64,
    lon: f64,
    now: i64,
) -> anyhow::Result<Place> {
    conn.execute(
        "INSERT INTO places (name, lat, lon, created_at) VALUES (?1, ?2, ?3, ?4)",
        params![name, lat, lon, now],
    )?;
    Ok(Place {
        id: conn.last_insert_rowid(),
        name: name.to_owned(),
        lat,
        lon,
    })
}

pub fn list_places(conn: &Connection) -> anyhow::Result<Vec<Place>> {
    let mut stmt = conn.prepare("SELECT id, name, lat, lon FROM places ORDER BY id")?;
    let rows = stmt.query_map([], |r| {
        Ok(Place {
            id: r.get(0)?,
            name: r.get(1)?,
            lat: r.get(2)?,
            lon: r.get(3)?,
        })
    })?;
    Ok(rows.collect::<Result<_, _>>()?)
}

pub fn find_place(conn: &Connection, id: i64) -> anyhow::Result<Option<Place>> {
    Ok(list_places(conn)?.into_iter().find(|p| p.id == id))
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
