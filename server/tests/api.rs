//! Health, access control and dev auth without an identity provider.

mod common;

use axum::body::Body;
use axum::http::{header, Request, StatusCode};
use common::{Auth, TestServer};

#[tokio::test]
async fn health_is_public() {
    let s = TestServer::with_config(|_| {});
    let r = s.get("/health", Auth::None).await;
    assert_eq!(r.status, StatusCode::OK);
    assert_eq!(r.json()["status"], "ok");
}

#[tokio::test]
async fn api_requires_login() {
    let s = TestServer::with_config(|_| {});
    let r = s.get("/api/v1/me", Auth::None).await;
    assert_eq!(r.status, StatusCode::UNAUTHORIZED);
    assert_eq!(r.json()["error"]["code"], "unauthorized");
    assert_eq!(
        s.get("/api/v1/me", Auth::Cookie("erfunden")).await.status,
        StatusCode::UNAUTHORIZED
    );
    // the start page sends the browser to the login
    let r = s.get("/", Auth::None).await;
    assert_eq!(r.status, StatusCode::SEE_OTHER);
    assert_eq!(r.header("location"), Some("/auth/login?return_to=/"));
    // without OIDC and dev auth there is no way in
    assert_eq!(
        s.get("/auth/login", Auth::None).await.status,
        StatusCode::SERVICE_UNAVAILABLE
    );
}

#[tokio::test]
async fn dev_auth_only_for_loopback_hosts() {
    let s = TestServer::with_config(|c| c.dev_auth = true);
    let r = s.get("/api/v1/me", Auth::None).await; // Host: localhost
    assert_eq!(r.status, StatusCode::OK);
    assert_eq!(r.json()["kind"], "dev");

    let foreign = |path: &str| {
        Request::get(path)
            .header(header::HOST, "witterung.example.org")
            .body(Body::empty())
            .unwrap()
    };
    assert_eq!(
        s.send(foreign("/api/v1/me")).await.status,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        s.send(foreign("/auth/login")).await.status,
        StatusCode::FORBIDDEN
    );

    // the dev login creates a real session cookie
    let r = s.get("/auth/login?return_to=/", Auth::None).await;
    assert_eq!(r.status, StatusCode::SEE_OTHER);
    let session = r.cookie("witterung_session").expect("session cookie");
    let req = Request::get("/api/v1/me")
        .header(header::HOST, "witterung.example.org")
        .header(header::COOKIE, format!("witterung_session={session}"))
        .body(Body::empty())
        .unwrap();
    assert_eq!(s.send(req).await.status, StatusCode::OK);
}

#[tokio::test]
async fn bearer_tokens_are_refused_until_devices_exist() {
    let s = TestServer::with_config(|c| c.dev_auth = true);
    let req = Request::get("/api/v1/me")
        .header(header::AUTHORIZATION, "Bearer irgendwas")
        .body(Body::empty())
        .unwrap();
    // even on localhost with dev auth: a token never falls back to anything else
    assert_eq!(s.send(req).await.status, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn web_app_files_with_csp() {
    let s = TestServer::with_config(|c| {
        c.dev_auth = true;
        c.web_dir = c.data_dir.join("web");
        std::fs::create_dir_all(c.web_dir.join("assets")).unwrap();
        std::fs::write(c.web_dir.join("index.html"), "<!doctype html>hallo").unwrap();
        std::fs::write(c.web_dir.join("assets/app.js"), "export {}").unwrap();
    });
    let r = s.get("/", Auth::None).await;
    assert_eq!(r.status, StatusCode::OK);
    assert!(r
        .header("content-security-policy")
        .unwrap()
        .contains("default-src 'self'"));
    let r = s.get("/assets/app.js", Auth::None).await;
    assert_eq!(
        r.header("content-type"),
        Some("text/javascript; charset=utf-8")
    );
    for bad in [
        "/assets/..%2Findex.html",
        "/assets/.hidden",
        "/assets/nope.js",
    ] {
        assert_eq!(
            s.get(bad, Auth::None).await.status,
            StatusCode::NOT_FOUND,
            "{bad}"
        );
    }
}
