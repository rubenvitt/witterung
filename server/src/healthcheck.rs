//! `witterung healthcheck`: asks the local server for `/health`
//! (Docker `HEALTHCHECK`).

use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::time::Duration;

/// The URL the health check requests for a bind address: the bound IP, or
/// `127.0.0.1` when bound to all interfaces.
pub fn health_url(bind: SocketAddr) -> String {
    let ip = match bind.ip() {
        ip if ip.is_unspecified() => IpAddr::V4(Ipv4Addr::LOCALHOST),
        ip => ip,
    };
    format!("http://{}/health", SocketAddr::new(ip, bind.port()))
}

/// Whether the server at `bind` answers `/health` with status `ok`.
pub async fn check(bind: SocketAddr) -> Result<(), String> {
    let url = health_url(bind);
    let client = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(3))
        .build()
        .map_err(|e| e.to_string())?;
    let response = client.get(&url).send().await.map_err(|e| e.to_string())?;
    if !response.status().is_success() {
        return Err(format!("{url} antwortet mit {}", response.status()));
    }
    let body: serde_json::Value = response.json().await.map_err(|e| e.to_string())?;
    if body["status"] == "ok" {
        Ok(())
    } else {
        Err(format!("{url} meldet {body}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn url_for_bind_address() {
        assert_eq!(
            health_url("0.0.0.0:8080".parse().unwrap()),
            "http://127.0.0.1:8080/health"
        );
        assert_eq!(
            health_url("[::]:9000".parse().unwrap()),
            "http://127.0.0.1:9000/health"
        );
        assert_eq!(
            health_url("10.0.0.5:8080".parse().unwrap()),
            "http://10.0.0.5:8080/health"
        );
    }
}
