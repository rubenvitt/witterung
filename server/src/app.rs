//! Shared application state: configuration, database, OIDC client.

use std::sync::{Arc, Mutex};

use rusqlite::Connection;

use crate::auth::oidc::OidcClient;
use crate::auth::{self, Principal};
use crate::config::Config;
use crate::db::{self, SessionOwner};
use crate::error::{AppError, AppResult};

#[derive(Clone)]
pub struct App {
    inner: Arc<Inner>,
}

struct Inner {
    config: Config,
    db: Mutex<Connection>,
    oidc: Option<Arc<OidcClient>>,
    http: reqwest::Client,
}

/// A freshly created session; `id` goes into the cookie.
pub struct NewSession {
    pub id: String,
}

/// A valid session; `renewed_until` is set when its expiry was extended
/// (the cookie must then be sent again).
pub struct SessionAuth {
    pub principal: Principal,
    pub renewed_until: Option<i64>,
}

pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as i64)
}

impl App {
    pub fn open(config: Config, http: reqwest::Client) -> anyhow::Result<Self> {
        let conn = db::open(&config.db_path())?;
        let oidc = config.oidc.clone().map(|oidc| {
            Arc::new(OidcClient::new(
                oidc,
                config.oidc_redirect_uri(),
                &config.session_secret,
                http.clone(),
            ))
        });
        Ok(Self {
            inner: Arc::new(Inner {
                config,
                db: Mutex::new(conn),
                oidc,
                http,
            }),
        })
    }

    pub fn config(&self) -> &Config {
        &self.inner.config
    }

    pub fn oidc(&self) -> Option<&Arc<OidcClient>> {
        self.inner.oidc.as_ref()
    }

    pub fn http(&self) -> &reqwest::Client {
        &self.inner.http
    }

    /// Runs `f` with the database on the blocking pool.
    pub async fn blocking<T: Send + 'static>(
        &self,
        f: impl FnOnce(&Connection) -> anyhow::Result<T> + Send + 'static,
    ) -> AppResult<T> {
        let inner = self.inner.clone();
        tokio::task::spawn_blocking(move || {
            let conn = inner.db.lock().unwrap_or_else(|e| e.into_inner());
            f(&conn)
        })
        .await
        .map_err(|e| AppError::Internal(e.into()))?
        .map_err(AppError::Internal)
    }

    fn session_key(&self) -> &[u8] {
        self.inner.config.session_secret.as_bytes()
    }

    pub async fn create_session(&self, owner: SessionOwner) -> AppResult<NewSession> {
        let id = auth::random_secret();
        let hash = auth::session_hash(self.session_key(), &id);
        let now = now_ms();
        let expires_at = now + auth::SESSION_TTL_MS;
        self.blocking(move |conn| {
            db::purge_expired_sessions(conn, now)?;
            db::insert_session(conn, &hash, &owner, now, expires_at)
        })
        .await?;
        Ok(NewSession { id })
    }

    /// Looks up a session by its raw ID and extends it (sliding expiry).
    pub async fn authenticate_session(&self, raw: &str) -> AppResult<Option<SessionAuth>> {
        let hash = auth::session_hash(self.session_key(), raw);
        let now = now_ms();
        self.blocking(move |conn| {
            let Some(session) = db::find_session(conn, &hash, now)? else {
                return Ok(None);
            };
            let renewed_until = if now - session.last_seen_at >= auth::SESSION_RENEW_AFTER_MS {
                let expires_at = now + auth::SESSION_TTL_MS;
                db::extend_session(conn, &hash, now, expires_at)?;
                Some(expires_at)
            } else {
                None
            };
            Ok(Some(SessionAuth {
                principal: Principal::Session(session.owner),
                renewed_until,
            }))
        })
        .await
    }

    pub async fn end_session(&self, raw: &str) -> AppResult<()> {
        let hash = auth::session_hash(self.session_key(), raw);
        self.blocking(move |conn| db::delete_session(conn, &hash))
            .await
    }
}
