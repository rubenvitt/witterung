//! Server configuration from environment variables (bootstrap only: address,
//! public URL, login). Everything else is configured in the app.
//!
//! Adapted from zunder (`crates/zunder-server/src/config.rs`).

use std::net::SocketAddr;
use std::path::PathBuf;

use url::Url;

/// Minimum length of `WITTERUNG_SESSION_SECRET`.
pub const MIN_SESSION_SECRET_LEN: usize = 32;

/// Key used to hash session IDs when dev auth runs without a session secret.
const DEV_SESSION_SECRET: &str = "witterung-dev-auth-session-secret-not-for-production";

/// Configuration error with a German, user-facing message.
#[derive(Debug, thiserror::Error)]
#[error("Konfigurationsfehler: {0}")]
pub struct ConfigError(pub String);

fn err<T>(msg: impl Into<String>) -> Result<T, ConfigError> {
    Err(ConfigError(msg.into()))
}

/// OpenID Connect settings (Pocket ID).
#[derive(Debug, Clone)]
pub struct OidcConfig {
    pub issuer: Url,
    pub client_id: String,
    /// `None` = public client (PKCE only).
    pub client_secret: Option<String>,
    pub allowed_subject: Option<String>,
    pub allowed_email: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Config {
    pub bind: SocketAddr,
    pub data_dir: PathBuf,
    pub public_url: Url,
    pub oidc: Option<OidcConfig>,
    /// Key for hashing session IDs (HMAC-SHA256).
    pub session_secret: String,
    pub dev_auth: bool,
}

impl Config {
    /// Reads the configuration from the process environment.
    pub fn from_env() -> Result<Self, ConfigError> {
        Self::from_lookup(|key| std::env::var(key).ok())
    }

    /// Reads the configuration through `lookup` (testable). Empty values
    /// count as unset.
    pub fn from_lookup(lookup: impl Fn(&str) -> Option<String>) -> Result<Self, ConfigError> {
        let get = |key: &str| {
            lookup(key)
                .map(|v| v.trim().to_owned())
                .filter(|v| !v.is_empty())
        };

        let flag = |key: &str| match get(key).as_deref() {
            None | Some("false") | Some("0") => Ok(false),
            Some("true") | Some("1") => Ok(true),
            Some(other) => err(format!("{key} muss true oder false sein: {other}")),
        };
        let dev_auth = flag("WITTERUNG_DEV_AUTH")?;
        let dev_auth_allow_remote = flag("WITTERUNG_DEV_AUTH_ALLOW_REMOTE")?;

        // Dev auth makes every request the owner, so it listens on loopback
        // only unless explicitly told otherwise (a container cannot bind its
        // host's loopback; it publishes the port with `-p 127.0.0.1:…`).
        let bind: SocketAddr = match get("WITTERUNG_BIND") {
            Some(v) => v
                .parse()
                .map_err(|_| ConfigError(format!("WITTERUNG_BIND ist keine Adresse: {v}")))?,
            None if dev_auth => SocketAddr::from(([127, 0, 0, 1], 8080)),
            None => SocketAddr::from(([0, 0, 0, 0], 8080)),
        };
        if dev_auth && !bind.ip().is_loopback() && !dev_auth_allow_remote {
            return err(format!(
                "WITTERUNG_DEV_AUTH=true lauscht nur auf einer lokalen Adresse \
                 (WITTERUNG_BIND ist {bind}); im Container \
                 WITTERUNG_DEV_AUTH_ALLOW_REMOTE=true setzen und den Port nur lokal \
                 veröffentlichen"
            ));
        }
        let data_dir = PathBuf::from(get("WITTERUNG_DATA_DIR").unwrap_or_else(|| "./data".into()));

        let public_url = match get("WITTERUNG_PUBLIC_URL") {
            Some(v) => Url::parse(&v)
                .map_err(|_| ConfigError(format!("WITTERUNG_PUBLIC_URL ist keine URL: {v}")))?,
            None => Url::parse(&format!("http://localhost:{}", bind.port()))
                .expect("static URL is valid"),
        };
        if !matches!(public_url.scheme(), "http" | "https") || public_url.host_str().is_none() {
            return err("WITTERUNG_PUBLIC_URL muss eine http(s)-URL sein");
        }

        if dev_auth && !is_loopback_url(&public_url) {
            return err(
                "WITTERUNG_DEV_AUTH=true ist nur mit einer lokalen WITTERUNG_PUBLIC_URL \
                 (localhost, 127.0.0.1, ::1) erlaubt",
            );
        }

        let oidc = match (
            get("WITTERUNG_OIDC_ISSUER"),
            get("WITTERUNG_OIDC_CLIENT_ID"),
        ) {
            (None, None) => None,
            (Some(issuer), Some(client_id)) => {
                let issuer = Url::parse(&issuer).map_err(|_| {
                    ConfigError(format!("WITTERUNG_OIDC_ISSUER ist keine URL: {issuer}"))
                })?;
                let allowed_subject = get("WITTERUNG_OIDC_ALLOWED_SUBJECT");
                let allowed_email = get("WITTERUNG_OIDC_ALLOWED_EMAIL").map(|e| e.to_lowercase());
                if allowed_subject.is_none() && allowed_email.is_none() {
                    return err(
                        "WITTERUNG_OIDC_ALLOWED_SUBJECT oder WITTERUNG_OIDC_ALLOWED_EMAIL muss gesetzt sein",
                    );
                }
                Some(OidcConfig {
                    issuer,
                    client_id,
                    client_secret: get("WITTERUNG_OIDC_CLIENT_SECRET"),
                    allowed_subject,
                    allowed_email,
                })
            }
            _ => {
                return err("WITTERUNG_OIDC_ISSUER und WITTERUNG_OIDC_CLIENT_ID gehören zusammen");
            }
        };

        let session_secret = match get("WITTERUNG_SESSION_SECRET") {
            Some(s) if s.len() >= MIN_SESSION_SECRET_LEN => s,
            Some(_) => {
                return err(format!(
                    "WITTERUNG_SESSION_SECRET muss mindestens {MIN_SESSION_SECRET_LEN} Zeichen lang sein"
                ));
            }
            None if oidc.is_some() && !dev_auth => {
                return err("WITTERUNG_SESSION_SECRET ist für den OIDC-Login erforderlich");
            }
            None => DEV_SESSION_SECRET.to_owned(),
        };

        Ok(Self {
            bind,
            data_dir,
            public_url,
            oidc,
            session_secret,
            dev_auth,
        })
    }

    /// A configuration for tests: everything in `data_dir`, no OIDC, no dev auth.
    pub fn for_data_dir(data_dir: impl Into<PathBuf>) -> Self {
        Self {
            bind: SocketAddr::from(([127, 0, 0, 1], 0)),
            data_dir: data_dir.into(),
            public_url: Url::parse("http://localhost:8080").expect("static URL is valid"),
            oidc: None,
            session_secret: DEV_SESSION_SECRET.to_owned(),
            dev_auth: false,
        }
    }

    /// Path of the SQLite database.
    pub fn db_path(&self) -> PathBuf {
        self.data_dir.join("witterung.db")
    }

    /// Session cookies are `Secure` unless the public URL is plain-http
    /// loopback (local development).
    pub fn secure_cookies(&self) -> bool {
        !(self.public_url.scheme() == "http" && is_loopback_url(&self.public_url))
    }

    /// The OIDC redirect URI (`<public_url>/auth/callback`).
    pub fn oidc_redirect_uri(&self) -> Url {
        self.public_url
            .join("auth/callback")
            .expect("joining a static path is valid")
    }
}

fn is_loopback_url(url: &Url) -> bool {
    match url.host() {
        Some(url::Host::Domain(d)) => d == "localhost",
        Some(url::Host::Ipv4(ip)) => ip.is_loopback(),
        Some(url::Host::Ipv6(ip)) => ip.is_loopback(),
        None => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn cfg(vars: &[(&str, &str)]) -> Result<Config, ConfigError> {
        let map: HashMap<String, String> = vars
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        Config::from_lookup(|k| map.get(k).cloned())
    }

    #[test]
    fn defaults() {
        let c = cfg(&[]).unwrap();
        assert_eq!(c.bind.to_string(), "0.0.0.0:8080");
        assert_eq!(c.data_dir, PathBuf::from("./data"));
        assert_eq!(c.public_url.as_str(), "http://localhost:8080/");
        assert!(!c.dev_auth);
        assert!(c.oidc.is_none());
        assert!(!c.secure_cookies());
        assert_eq!(c.db_path(), PathBuf::from("./data/witterung.db"));
    }

    #[test]
    fn full_oidc_config() {
        let c = cfg(&[
            ("WITTERUNG_BIND", "127.0.0.1:9000"),
            ("WITTERUNG_PUBLIC_URL", "https://witterung.example.org"),
            ("WITTERUNG_OIDC_ISSUER", "https://id.example.org"),
            ("WITTERUNG_OIDC_CLIENT_ID", "witterung"),
            ("WITTERUNG_OIDC_CLIENT_SECRET", "geheim"),
            ("WITTERUNG_OIDC_ALLOWED_EMAIL", "Person@Example.org"),
            (
                "WITTERUNG_SESSION_SECRET",
                "0123456789abcdef0123456789abcdef",
            ),
        ])
        .unwrap();
        let oidc = c.oidc.as_ref().unwrap();
        assert_eq!(oidc.allowed_email.as_deref(), Some("person@example.org"));
        assert!(c.secure_cookies());
        assert_eq!(
            c.oidc_redirect_uri().as_str(),
            "https://witterung.example.org/auth/callback"
        );
    }

    #[test]
    fn rejects_invalid_values() {
        assert!(cfg(&[("WITTERUNG_BIND", "nope")]).is_err());
        assert!(cfg(&[("WITTERUNG_DEV_AUTH", "yes")]).is_err());
        assert!(cfg(&[("WITTERUNG_OIDC_ISSUER", "https://id.example.org")]).is_err());
        // OIDC without allowed person
        assert!(cfg(&[
            ("WITTERUNG_OIDC_ISSUER", "https://id.example.org"),
            ("WITTERUNG_OIDC_CLIENT_ID", "witterung"),
            (
                "WITTERUNG_SESSION_SECRET",
                "0123456789abcdef0123456789abcdef"
            ),
        ])
        .is_err());
        // OIDC without session secret
        assert!(cfg(&[
            ("WITTERUNG_OIDC_ISSUER", "https://id.example.org"),
            ("WITTERUNG_OIDC_CLIENT_ID", "witterung"),
            ("WITTERUNG_OIDC_ALLOWED_SUBJECT", "abc"),
        ])
        .is_err());
        assert!(cfg(&[("WITTERUNG_SESSION_SECRET", "kurz")]).is_err());
    }

    #[test]
    fn dev_auth_only_on_loopback() {
        assert!(cfg(&[("WITTERUNG_DEV_AUTH", "true")]).unwrap().dev_auth);
        assert!(
            cfg(&[
                ("WITTERUNG_DEV_AUTH", "true"),
                ("WITTERUNG_PUBLIC_URL", "http://127.0.0.1:5173")
            ])
            .unwrap()
            .dev_auth
        );
        assert!(cfg(&[
            ("WITTERUNG_DEV_AUTH", "true"),
            ("WITTERUNG_PUBLIC_URL", "https://witterung.example.org")
        ])
        .is_err());
    }

    #[test]
    fn dev_auth_binds_loopback_only() {
        let c = cfg(&[("WITTERUNG_DEV_AUTH", "true")]).unwrap();
        assert_eq!(c.bind.to_string(), "127.0.0.1:8080");
        assert!(cfg(&[
            ("WITTERUNG_DEV_AUTH", "true"),
            ("WITTERUNG_BIND", "[::1]:9000")
        ])
        .is_ok());
        for bind in ["0.0.0.0:8080", "[::]:8080", "192.0.2.2:8080"] {
            assert!(
                cfg(&[("WITTERUNG_DEV_AUTH", "true"), ("WITTERUNG_BIND", bind)]).is_err(),
                "{bind}"
            );
        }
        // explicit escape hatch for containers
        let c = cfg(&[
            ("WITTERUNG_DEV_AUTH", "true"),
            ("WITTERUNG_BIND", "0.0.0.0:8080"),
            ("WITTERUNG_DEV_AUTH_ALLOW_REMOTE", "true"),
        ])
        .unwrap();
        assert!(c.dev_auth);
        assert!(cfg(&[("WITTERUNG_DEV_AUTH_ALLOW_REMOTE", "ja")]).is_err());
    }
}
