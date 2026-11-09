//! Request authentication for `/api` (and other protected routes).

use std::net::IpAddr;

use axum::extract::{FromRequestParts, Request, State};
use axum::http::header::{AUTHORIZATION, COOKIE, HOST, SET_COOKIE};
use axum::http::request::Parts;
use axum::http::uri::Authority;
use axum::http::{HeaderMap, HeaderValue, Method};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use cookie::{Cookie, SameSite};

use super::{has_client_header, missing_client_header, Principal, SESSION_COOKIE};
use crate::app::{now_ms, App};
use crate::error::AppError;

/// The value of a cookie in the request.
pub fn cookie_value<'a>(headers: &'a HeaderMap, name: &str) -> Option<&'a str> {
    headers
        .get_all(COOKIE)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|v| v.split(';'))
        .filter_map(|pair| pair.trim().split_once('='))
        .find(|(k, _)| *k == name)
        .map(|(_, v)| v.trim())
}

/// The `Set-Cookie` value for a session.
pub fn session_cookie(app: &App, id: &str, max_age_ms: i64) -> HeaderValue {
    let cookie = Cookie::build((SESSION_COOKIE, id.to_owned()))
        .http_only(true)
        .secure(app.config().secure_cookies())
        .same_site(SameSite::Lax)
        .path("/")
        .max_age(time::Duration::milliseconds(max_age_ms.max(0)))
        .build();
    HeaderValue::from_str(&cookie.to_string()).expect("cookie is a valid header value")
}

/// The `Set-Cookie` value that removes the session cookie.
pub fn clear_session_cookie(app: &App) -> HeaderValue {
    session_cookie(app, "", 0)
}

/// Whether the `Host` header names a loopback host (`localhost`,
/// `127.0.0.0/8`, `[::1]`) on any port.
fn is_loopback_host(headers: &HeaderMap) -> bool {
    let Some(authority) = headers
        .get(HOST)
        .and_then(|v| v.to_str().ok())
        .filter(|v| !v.contains('@'))
        .and_then(|v| v.parse::<Authority>().ok())
    else {
        return false;
    };
    let host = authority.host();
    let host = host
        .strip_prefix('[')
        .and_then(|h| h.strip_suffix(']'))
        .unwrap_or(host);
    host.eq_ignore_ascii_case("localhost")
        || host.parse::<IpAddr>().is_ok_and(|ip| ip.is_loopback())
}

/// Whether dev auth may stand in for credentials on this request: only with
/// `WITTERUNG_DEV_AUTH=true` and only for requests addressed to a loopback
/// host, so neither another machine nor a DNS-rebinding website (whose
/// requests carry its own host name) acts as the owner.
pub fn dev_auth_applies(app: &App, headers: &HeaderMap) -> bool {
    app.config().dev_auth && is_loopback_host(headers)
}

fn is_safe_method(method: &Method) -> bool {
    matches!(*method, Method::GET | Method::HEAD | Method::OPTIONS)
}

/// Requires a principal (session cookie or dev auth), enforces the CSRF
/// header for browser principals on state-changing requests, and renews the
/// session cookie when its sliding expiry was extended.
pub async fn require_auth(State(app): State<App>, mut req: Request, next: Next) -> Response {
    let mut renewed: Option<HeaderValue> = None;
    let principal = match authenticate(&app, req.headers(), &mut renewed).await {
        Ok(p) => p,
        Err(e) => return e.into_response(),
    };
    if principal.is_browser() && !is_safe_method(req.method()) && !has_client_header(req.headers())
    {
        return missing_client_header().into_response();
    }
    req.extensions_mut().insert(principal);
    let mut response = next.run(req).await;
    if let Some(cookie) = renewed {
        response.headers_mut().append(SET_COOKIE, cookie);
    }
    response
}

async fn authenticate(
    app: &App,
    headers: &HeaderMap,
    renewed: &mut Option<HeaderValue>,
) -> Result<Principal, AppError> {
    // No bearer tokens exist yet (device tokens follow in M3). A request that
    // sends one is refused instead of falling back to the cookie.
    if headers.contains_key(AUTHORIZATION) {
        return Err(AppError::Unauthorized);
    }
    if let Some(principal) = browser_principal(app, headers, Some(renewed)).await? {
        return Ok(principal);
    }
    Err(AppError::Unauthorized)
}

/// The browser principal of a request (session cookie, or dev auth without a
/// valid cookie). Fills `renewed` with a fresh cookie when the session was
/// extended.
pub async fn browser_principal(
    app: &App,
    headers: &HeaderMap,
    renewed: Option<&mut Option<HeaderValue>>,
) -> Result<Option<Principal>, AppError> {
    if let Some(id) = cookie_value(headers, SESSION_COOKIE).filter(|v| !v.is_empty()) {
        if let Some(auth) = app.authenticate_session(id).await? {
            if let (Some(expires_at), Some(renewed)) = (auth.renewed_until, renewed) {
                *renewed = Some(session_cookie(app, id, expires_at - now_ms()));
            }
            return Ok(Some(auth.principal));
        }
    }
    if dev_auth_applies(app, headers) {
        return Ok(Some(Principal::DevAuto));
    }
    Ok(None)
}

/// Handlers behind [`require_auth`] take the principal as an extractor.
impl<S: Send + Sync> FromRequestParts<S> for Principal {
    type Rejection = AppError;

    async fn from_request_parts(parts: &mut Parts, _state: &S) -> Result<Self, Self::Rejection> {
        parts
            .extensions
            .get::<Principal>()
            .cloned()
            .ok_or(AppError::Unauthorized)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_cookies_and_hosts() {
        let mut h = HeaderMap::new();
        h.append(
            COOKIE,
            HeaderValue::from_static("a=1; witterung_session=xyz"),
        );
        h.append(COOKIE, HeaderValue::from_static("b=2"));
        assert_eq!(cookie_value(&h, "witterung_session"), Some("xyz"));
        assert_eq!(cookie_value(&h, "b"), Some("2"));
        assert_eq!(cookie_value(&h, "c"), None);

        for (host, loopback) in [
            ("localhost:8080", true),
            ("127.0.0.1", true),
            ("[::1]:8080", true),
            ("witterung.example.org", false),
            ("localhost.evil.example", false),
            ("user@localhost", false),
        ] {
            let mut h = HeaderMap::new();
            h.insert(HOST, HeaderValue::from_str(host).unwrap());
            assert_eq!(is_loopback_host(&h), loopback, "{host}");
        }
    }
}
