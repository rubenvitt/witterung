//! Authentication: principals, sessions, CSRF rule and OIDC.
//!
//! Adapted from zunder (`crates/zunder-server/src/auth`).
//!
//! - **Sessions**: cookie [`SESSION_COOKIE`] with a random 32-byte ID, stored
//!   as HMAC-SHA256 (key `WITTERUNG_SESSION_SECRET`), 30 days sliding expiry.
//! - **CSRF**: cookie-authenticated requests that change state must carry the
//!   header [`CLIENT_HEADER`] (`X-Witterung-Client: web`). Browsers cannot add
//!   custom headers cross-site without a CORS preflight, which is never granted.
//! - **Bearer tokens** (device tokens of the iOS app) follow in M3; until then
//!   every `Authorization` header is rejected.

pub mod middleware;
pub mod oidc;
pub mod routes;

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};

use crate::db::SessionOwner;

/// Name of the session cookie.
pub const SESSION_COOKIE: &str = "witterung_session";
/// Header that cookie-authenticated, state-changing requests must send.
pub const CLIENT_HEADER: &str = "x-witterung-client";
/// Session lifetime (sliding).
pub const SESSION_TTL_MS: i64 = 30 * 24 * 60 * 60 * 1000;
/// A session is extended at most this often.
pub const SESSION_RENEW_AFTER_MS: i64 = 24 * 60 * 60 * 1000;

/// Who is making a request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Principal {
    /// Browser session (cookie).
    Session(SessionOwner),
    /// `WITTERUNG_DEV_AUTH=true` on a loopback host, without credentials.
    DevAuto,
}

impl Principal {
    /// Authenticated like a browser: subject to the CSRF rule.
    pub fn is_browser(&self) -> bool {
        matches!(self, Principal::Session(_) | Principal::DevAuto)
    }
}

/// The person a completed OIDC login identified.
#[derive(Debug, Clone)]
pub struct Identity {
    pub subject: String,
    pub email: Option<String>,
    pub name: Option<String>,
}

impl From<Identity> for SessionOwner {
    fn from(i: Identity) -> Self {
        SessionOwner {
            subject: Some(i.subject),
            name: i.name,
            email: i.email,
        }
    }
}

/// Whether a request carries the CSRF header ([`CLIENT_HEADER`], non-empty).
pub fn has_client_header(headers: &axum::http::HeaderMap) -> bool {
    headers
        .get(CLIENT_HEADER)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| !v.trim().is_empty())
}

/// The error for a missing CSRF header.
pub fn missing_client_header() -> crate::error::AppError {
    crate::error::AppError::Forbidden(
        "Header X-Witterung-Client fehlt (Schutz vor Cross-Site-Anfragen)".into(),
    )
}

/// 32 random bytes as base64url without padding (43 characters).
pub fn random_secret() -> String {
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes).expect("operating system RNG is available");
    URL_SAFE_NO_PAD.encode(bytes)
}

/// Keyed hash of a session ID (storage form of sessions).
pub fn session_hash(key: &[u8], session_id: &str) -> String {
    let mut mac = Hmac::<Sha256>::new_from_slice(key).expect("HMAC accepts any key length");
    mac.update(session_id.as_bytes());
    hex(&mac.finalize().into_bytes())
}

/// PKCE S256 code challenge for a verifier.
pub fn pkce_challenge(verifier: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()))
}

fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write;
    bytes
        .iter()
        .fold(String::with_capacity(bytes.len() * 2), |mut s, b| {
            let _ = write!(s, "{b:02x}");
            s
        })
}

/// Constant-time equality for secrets of equal length.
pub fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hashes() {
        assert_ne!(session_hash(b"k1", "s"), session_hash(b"k2", "s"));
        assert_eq!(session_hash(b"k1", "s").len(), 64);
        // RFC 7636 appendix B
        assert_eq!(
            pkce_challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        );
        assert!(constant_time_eq(b"abc", b"abc"));
        assert!(!constant_time_eq(b"abc", b"abd"));
        assert!(!constant_time_eq(b"abc", b"ab"));
        let s = random_secret();
        assert_eq!(s.len(), 43);
        assert_ne!(s, random_secret());
    }
}
