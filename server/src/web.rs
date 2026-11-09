//! The web app (`web/`, M7): `index.html` at `/`, files of `web/assets/` at
//! `/assets/<name>`. Read from `WITTERUNG_WEB_DIR` at request time (small,
//! one user; no caching layer needed).

use axum::extract::{Path, State};
use axum::http::header::{CACHE_CONTROL, CONTENT_SECURITY_POLICY, CONTENT_TYPE};
use axum::http::{HeaderMap, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Redirect, Response};

use crate::app::App;
use crate::auth::middleware::browser_principal;
use crate::error::{AppError, AppResult};

pub const CSP: &str = "default-src 'self'; img-src 'self' data: https://maps.dwd.de \
    https://*.tile.openstreetmap.org; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'";

fn content_type(name: &str) -> &'static str {
    match name.rsplit_once('.').map(|(_, e)| e) {
        Some("html") => "text/html; charset=utf-8",
        Some("js" | "mjs") => "text/javascript; charset=utf-8",
        Some("css") => "text/css; charset=utf-8",
        Some("svg") => "image/svg+xml",
        Some("png") => "image/png",
        Some("json") => "application/json",
        Some("woff2") => "font/woff2",
        Some("txt" | "md") => "text/plain; charset=utf-8",
        _ => "application/octet-stream",
    }
}

fn file_response(bytes: Vec<u8>, name: &str, cache: &'static str) -> Response {
    let mut r = bytes.into_response();
    let h = r.headers_mut();
    h.insert(CONTENT_TYPE, HeaderValue::from_static(content_type(name)));
    h.insert(CACHE_CONTROL, HeaderValue::from_static(cache));
    h.insert(CONTENT_SECURITY_POLICY, HeaderValue::from_static(CSP));
    h.insert(
        "x-content-type-options",
        HeaderValue::from_static("nosniff"),
    );
    r
}

/// `/`: the app for a signed-in browser, else the login.
pub async fn index(State(app): State<App>, headers: HeaderMap) -> AppResult<Response> {
    if browser_principal(&app, &headers, None).await?.is_none() {
        return Ok(Redirect::to("/auth/login?return_to=/").into_response());
    }
    let path = app.config().web_dir.join("index.html");
    let bytes = tokio::fs::read(&path)
        .await
        .map_err(|e| AppError::Internal(anyhow::anyhow!("{}: {e}", path.display())))?;
    Ok(file_response(bytes, "index.html", "no-cache"))
}

/// `/assets/<name>`: flat directory, plain file names only.
pub async fn asset(State(app): State<App>, Path(name): Path<String>) -> Response {
    let safe = !name.is_empty()
        && !name.starts_with('.')
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_'));
    if !safe {
        return StatusCode::NOT_FOUND.into_response();
    }
    match tokio::fs::read(app.config().web_dir.join("assets").join(&name)).await {
        Ok(bytes) => file_response(bytes, &name, "no-cache"),
        Err(_) => StatusCode::NOT_FOUND.into_response(),
    }
}
