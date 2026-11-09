//! Device sign-in (PKCE code → bearer token) and bearer access.

mod common;

use axum::body::Body;
use axum::http::{header, Request, StatusCode};
use common::{Auth, TestServer};

const VERIFIER: &str = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
const CHALLENGE: &str = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM";

async fn approve(s: &TestServer) -> String {
    let page = s
        .get(
            &format!("/auth/device/start?challenge={CHALLENGE}&name=Testger%C3%A4t"),
            Auth::None,
        )
        .await;
    assert_eq!(page.status, StatusCode::OK, "{}", page.text());
    assert!(page.text().contains("Testgerät"));
    let r = s
        .send(
            Request::post("/auth/device/approve")
                .header(header::CONTENT_TYPE, "application/x-www-form-urlencoded")
                .header(header::ORIGIN, "http://localhost:8080")
                .body(Body::from(format!(
                    "challenge={CHALLENGE}&name=Testger%C3%A4t"
                )))
                .unwrap(),
        )
        .await;
    assert_eq!(r.status, StatusCode::SEE_OTHER, "{}", r.text());
    let location = r.header("location").unwrap().to_owned();
    location
        .strip_prefix("witterung://auth?code=")
        .unwrap_or_else(|| panic!("{location}"))
        .to_owned()
}

async fn exchange(s: &TestServer, code: &str, verifier: &str) -> common::TestResponse {
    s.send(
        Request::post("/auth/device/token")
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(format!(
                r#"{{"code":"{code}","verifier":"{verifier}"}}"#
            )))
            .unwrap(),
    )
    .await
}

fn bearer(path: &str, token: &str) -> Request<Body> {
    Request::get(path)
        .header(header::HOST, "witterung.example.org")
        .header(header::AUTHORIZATION, format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

#[tokio::test]
async fn device_flow_issues_a_working_token() {
    let s = TestServer::with_config(|c| c.dev_auth = true);
    let code = approve(&s).await;

    // Wrong verifier: refused, and the code is gone afterwards.
    let wrong = "x".repeat(43);
    assert_eq!(
        exchange(&s, &code, &wrong).await.status,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        exchange(&s, &code, VERIFIER).await.status,
        StatusCode::BAD_REQUEST,
        "single use"
    );

    let code = approve(&s).await;
    let r = exchange(&s, &code, VERIFIER).await;
    assert_eq!(r.status, StatusCode::OK, "{}", r.text());
    let token = r.json()["token"].as_str().unwrap().to_owned();
    assert!(token.starts_with("wt_"));

    // Bearer works from any host (no dev auth involved) …
    let me = s.send(bearer("/api/v1/me", &token)).await;
    assert_eq!(me.status, StatusCode::OK);
    assert_eq!(me.json()["kind"], "device");
    assert_eq!(me.json()["name"], "Testgerät");
    // … needs no CSRF header for writes …
    let created = s
        .send(
            Request::post("/api/v1/places")
                .header(header::HOST, "witterung.example.org")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(r#"{"name":"A","lat":1,"lon":2}"#))
                .unwrap(),
        )
        .await;
    assert_eq!(created.status, StatusCode::CREATED);
    // … and a wrong token never falls back to anything else.
    assert_eq!(
        s.send(bearer("/api/v1/me", "wt_falsch")).await.status,
        StatusCode::UNAUTHORIZED
    );

    // Revoking the device ends the token.
    let devices = s.get("/api/v1/devices", Auth::None).await.json();
    let id = devices[0]["id"].as_i64().unwrap();
    let del = s
        .send(
            Request::delete(format!("/api/v1/devices/{id}"))
                .header("x-witterung-client", "test")
                .body(Body::empty())
                .unwrap(),
        )
        .await;
    assert_eq!(del.status, StatusCode::NO_CONTENT);
    assert_eq!(
        s.send(bearer("/api/v1/me", &token)).await.status,
        StatusCode::UNAUTHORIZED
    );
}

#[tokio::test]
async fn start_requires_login_and_a_valid_challenge() {
    let s = TestServer::with_config(|_| {});
    let r = s
        .get(
            &format!("/auth/device/start?challenge={CHALLENGE}"),
            Auth::None,
        )
        .await;
    assert_eq!(r.status, StatusCode::SEE_OTHER);
    assert!(r
        .header("location")
        .unwrap()
        .starts_with("/auth/login?return_to=%2Fauth%2Fdevice%2Fstart"));
    let s = TestServer::with_config(|c| c.dev_auth = true);
    assert_eq!(
        s.get("/auth/device/start?challenge=kurz", Auth::None)
            .await
            .status,
        StatusCode::BAD_REQUEST
    );
    // A cross-site form post is refused.
    let r = s
        .send(
            Request::post("/auth/device/approve")
                .header(header::HOST, "witterung.example.org")
                .header(header::CONTENT_TYPE, "application/x-www-form-urlencoded")
                .header(header::ORIGIN, "https://evil.example")
                .body(Body::from(format!("challenge={CHALLENGE}")))
                .unwrap(),
        )
        .await;
    assert_ne!(r.status, StatusCode::SEE_OTHER);
}
