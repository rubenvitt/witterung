//! Device sign-in for the iOS app: PKCE-bound one-time code, exchanged for a
//! long-lived bearer token (`wt_…`, stored as HMAC like sessions).
//!
//! 1. `GET /auth/device/start?challenge&name` (in ASWebAuthenticationSession):
//!    needs a browser session (else via the Pocket ID login) and shows a
//!    confirmation page, so a foreign app cannot silently obtain a code.
//! 2. `POST /auth/device/approve` (that page's form; the Lax session cookie is
//!    not sent cross-site, the Origin is checked too) → `witterung://auth?code=…`.
//! 3. `POST /auth/device/token {code, verifier}` → `{token, device_id}`.
//!
//! Clients without a browser (the Mac menu bar) get their token from the CLI
//! instead: `witterung device-add NAME` calls [`issue_token`] directly.

use axum::extract::{Query, State};
use axum::http::header::{CACHE_CONTROL, LOCATION, ORIGIN};
use axum::http::{HeaderMap, HeaderValue, StatusCode};
use axum::response::{Html, IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Form, Json, Router};
use serde::Deserialize;
use serde_json::{json, Value};

use super::middleware::browser_principal;
use super::{constant_time_eq, pkce_challenge, random_secret, session_hash, Principal};
use crate::app::{now_ms, App};
use crate::db;
use crate::error::{AppError, AppResult};

const CODE_TTL_MS: i64 = 5 * 60_000;
pub const TOKEN_PREFIX: &str = "wt_";
const CALLBACK: &str = "witterung://auth";

pub fn routes() -> Router<App> {
    Router::new()
        .route("/auth/device/start", get(start))
        .route("/auth/device/approve", post(approve))
        .route("/auth/device/token", post(token))
}

#[derive(Deserialize)]
struct Start {
    challenge: String,
    name: Option<String>,
}

fn valid_challenge(c: &str) -> bool {
    c.len() == 43
        && c.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

fn clean_name(name: Option<&str>) -> String {
    let name: String = name
        .unwrap_or("")
        .chars()
        .filter(|c| !c.is_control())
        .take(60)
        .collect();
    let name = name.trim();
    if name.is_empty() {
        "iPhone".into()
    } else {
        name.to_owned()
    }
}

fn escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

fn no_store(mut r: Response) -> Response {
    r.headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("no-store"));
    r
}

async fn start(
    State(app): State<App>,
    headers: HeaderMap,
    Query(q): Query<Start>,
) -> AppResult<Response> {
    if !valid_challenge(&q.challenge) {
        return Err(AppError::BadRequest(
            "challenge muss S256 (base64url, 43 Zeichen) sein".into(),
        ));
    }
    let name = clean_name(q.name.as_deref());
    if browser_principal(&app, &headers, None).await?.is_none() {
        let back = format!(
            "/auth/device/start?challenge={}&name={}",
            q.challenge,
            url::form_urlencoded::byte_serialize(name.as_bytes()).collect::<String>()
        );
        let to = format!(
            "/auth/login?return_to={}",
            url::form_urlencoded::byte_serialize(back.as_bytes()).collect::<String>()
        );
        let mut r = StatusCode::SEE_OTHER.into_response();
        r.headers_mut().insert(
            LOCATION,
            HeaderValue::from_str(&to).map_err(|e| AppError::Internal(e.into()))?,
        );
        return Ok(no_store(r));
    }
    let (c, n) = (escape(&q.challenge), escape(&name));
    Ok(no_store(Html(format!(
        "<!doctype html><html lang=\"de\"><head><meta charset=\"utf-8\">\
         <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\
         <title>Gerät anmelden – Witterung</title></head>\
         <body style=\"font-family: system-ui, sans-serif; max-width: 28rem; margin: 3rem auto; padding: 0 1rem\">\
         <h1>Gerät anmelden</h1><p>Soll <strong>{n}</strong> Zugriff auf Witterung bekommen?</p>\
         <form method=\"post\" action=\"/auth/device/approve\">\
         <input type=\"hidden\" name=\"challenge\" value=\"{c}\"><input type=\"hidden\" name=\"name\" value=\"{n}\">\
         <button type=\"submit\" style=\"font-size: 1.1rem; padding: .6rem 1.4rem\">Zulassen</button></form>\
         <p style=\"color: #666\">Nicht von dir gestartet? Dann einfach schließen.</p></body></html>"
    ))
    .into_response()))
}

#[derive(Deserialize)]
struct Approve {
    challenge: String,
    name: Option<String>,
}

async fn approve(
    State(app): State<App>,
    headers: HeaderMap,
    Form(f): Form<Approve>,
) -> AppResult<Response> {
    // Same-origin form only (defence in depth next to SameSite=Lax).
    if let Some(origin) = headers.get(ORIGIN).and_then(|v| v.to_str().ok()) {
        let own = app.config().public_url.origin().ascii_serialization();
        if origin != own && !crate::auth::middleware::dev_auth_applies(&app, &headers) {
            return Err(AppError::Forbidden("fremde Herkunft".into()));
        }
    }
    let Some(principal) = browser_principal(&app, &headers, None).await? else {
        return Err(AppError::Unauthorized);
    };
    if !valid_challenge(&f.challenge) {
        return Err(AppError::BadRequest("ungültige challenge".into()));
    }
    let subject = match principal {
        Principal::Session(o) => o.subject,
        _ => None,
    };
    let code = random_secret();
    let hash = app.secret_hash(&code);
    let name = clean_name(f.name.as_deref());
    let challenge = f.challenge;
    app.blocking(move |c| {
        db::insert_device_code(
            c,
            &hash,
            &challenge,
            &name,
            subject.as_deref(),
            now_ms() + CODE_TTL_MS,
        )
    })
    .await?;
    let mut r = StatusCode::SEE_OTHER.into_response();
    r.headers_mut().insert(
        LOCATION,
        HeaderValue::from_str(&format!("{CALLBACK}?code={code}"))
            .map_err(|e| AppError::Internal(e.into()))?,
    );
    Ok(no_store(r))
}

#[derive(Deserialize)]
struct TokenRequest {
    code: String,
    verifier: String,
}

async fn token(State(app): State<App>, Json(req): Json<TokenRequest>) -> AppResult<Json<Value>> {
    let v = &req.verifier;
    if !(43..=128).contains(&v.len())
        || !v
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-._~".contains(&b))
    {
        return Err(AppError::BadRequest("ungültiger verifier".into()));
    }
    let hash = app.secret_hash(&req.code);
    let now = now_ms();
    let Some((challenge, name, subject)) = app
        .blocking(move |c| db::take_device_code(c, &hash, now))
        .await?
    else {
        return Err(AppError::BadRequest(
            "Code unbekannt oder abgelaufen".into(),
        ));
    };
    if !constant_time_eq(pkce_challenge(v).as_bytes(), challenge.as_bytes()) {
        return Err(AppError::BadRequest("verifier passt nicht".into()));
    }
    let key = app.config().session_secret.clone();
    let (token, id) = app
        .blocking(move |c| issue_token(c, &key, &name, subject.as_deref(), now))
        .await?;
    tracing::info!(device = id, "device signed in");
    Ok(Json(json!({"token": token, "device_id": id})))
}

/// Creates a device and returns its new bearer token (shown once, stored
/// only as HMAC with `session_secret`) and its id.
pub fn issue_token(
    conn: &rusqlite::Connection,
    session_secret: &str,
    name: &str,
    subject: Option<&str>,
    now: i64,
) -> anyhow::Result<(String, i64)> {
    let token = format!("{TOKEN_PREFIX}{}", random_secret());
    let hash = session_hash(session_secret.as_bytes(), &token);
    let id = db::insert_device(conn, name, &hash, subject, now)?;
    Ok((token, id))
}
