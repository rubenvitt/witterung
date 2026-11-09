//! Polling against a local mock upstream: one source failing must not break
//! the others, and quota/backoff bookkeeping holds.

mod common;

use axum::body::Body;
use axum::http::{header, Request, StatusCode};
use axum::routing::get;
use axum::Router;
use common::{Auth, TestServer};
use jiff::{SignedDuration, Timestamp};
use url::Url;
use witterung::poller::poll_once;

const OPEN_METEO: &[u8] = include_bytes!("fixtures/open_meteo/uelzen.json");

/// Open-Meteo answers with the fixture, Bright Sky with HTTP 500.
async fn mock_upstreams() -> Url {
    let app = Router::new()
        .route("/om/forecast", get(|| async { OPEN_METEO }))
        .route(
            "/bs/weather",
            get(|| async { (StatusCode::INTERNAL_SERVER_ERROR, "kaputt") }),
        );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = Url::parse(&format!("http://{}/", listener.local_addr().unwrap())).unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    base
}

async fn server_with_place() -> (TestServer, i64) {
    let base = mock_upstreams().await;
    let s = TestServer::with_config(|c| {
        c.dev_auth = true;
        c.endpoints.open_meteo = base.join("om/").unwrap();
        c.endpoints.bright_sky = base.join("bs/").unwrap();
    });
    let r = s
        .send(
            Request::post("/api/v1/places")
                .header(header::CONTENT_TYPE, "application/json")
                .header("x-witterung-client", "test")
                .body(Body::from(r#"{"name":"Testort","lat":52.97,"lon":10.56}"#))
                .unwrap(),
        )
        .await;
    assert_eq!(r.status, StatusCode::CREATED, "{}", r.text());
    let id = r.json()["id"].as_i64().unwrap();
    (s, id)
}

fn provider<'a>(raw: &'a serde_json::Value, name: &str) -> &'a serde_json::Value {
    raw["providers"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["provider"] == name)
        .unwrap()
}

#[tokio::test]
async fn failing_source_does_not_break_the_others() {
    let (s, id) = server_with_place().await;
    let now = Timestamp::now();
    poll_once(&s.app, now).await;

    let r = s.get(&format!("/api/v1/places/{id}/raw"), Auth::None).await;
    assert_eq!(r.status, StatusCode::OK, "{}", r.text());
    let raw = r.json();
    let sources: Vec<&str> = raw["sources"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["source"].as_str().unwrap())
        .collect();
    assert_eq!(
        sources,
        [
            "open_meteo:ecmwf_ifs",
            "open_meteo:gfs",
            "open_meteo:icon_d2",
            "open_meteo:icon_eu"
        ]
    );
    assert_eq!(raw["sources"][0]["stale"], false);
    assert!(raw["sources"][0]["hourly"][0]["temp_c"].is_number());

    let om = provider(&raw, "open_meteo");
    assert_eq!(om["state"]["failures"], 0);
    assert!(om["quota"]["used"].as_f64().unwrap() > 0.0);
    let bs = provider(&raw, "bright_sky");
    assert_eq!(bs["state"]["failures"], 1);
    assert!(bs["state"]["error"].as_str().unwrap().contains("500"));
    // Failed calls count against the quota too.
    assert_eq!(bs["quota"]["used"], 1.0);
    assert_eq!(raw["attribution"].as_array().unwrap().len(), 2);
}

#[tokio::test]
async fn polls_again_only_when_due() {
    let (s, id) = server_with_place().await;
    let t0 = Timestamp::now();
    poll_once(&s.app, t0).await;
    // 30 s later: Open-Meteo is not due, Bright Sky waits for its backoff.
    poll_once(&s.app, t0 + SignedDuration::from_secs(30)).await;
    let raw = s
        .get(&format!("/api/v1/places/{id}/raw"), Auth::None)
        .await
        .json();
    assert_eq!(provider(&raw, "bright_sky")["quota"]["used"], 1.0);
    let om_used = provider(&raw, "open_meteo")["quota"]["used"]
        .as_f64()
        .unwrap();

    // After 1 min the backoff has passed: one more Bright Sky attempt.
    poll_once(&s.app, t0 + SignedDuration::from_secs(61)).await;
    let raw = s
        .get(&format!("/api/v1/places/{id}/raw"), Auth::None)
        .await
        .json();
    assert_eq!(provider(&raw, "bright_sky")["quota"]["used"], 2.0);
    assert_eq!(provider(&raw, "bright_sky")["state"]["failures"], 2);
    assert_eq!(
        provider(&raw, "open_meteo")["quota"]["used"]
            .as_f64()
            .unwrap(),
        om_used
    );
}

#[tokio::test]
async fn place_validation_and_unknown_place() {
    let (s, _) = server_with_place().await;
    let r = s
        .send(
            Request::post("/api/v1/places")
                .header(header::CONTENT_TYPE, "application/json")
                .header("x-witterung-client", "test")
                .body(Body::from(r#"{"name":"x","lat":95,"lon":10}"#))
                .unwrap(),
        )
        .await;
    assert_eq!(r.status, StatusCode::BAD_REQUEST);
    assert_eq!(
        s.get("/api/v1/places/999/raw", Auth::None).await.status,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        s.get("/api/v1/places", Auth::None).await.json()[0]["name"],
        "Testort"
    );
}

#[tokio::test]
async fn credential_sources_poll_when_configured() {
    use base64::Engine;
    use ring::signature::{EcdsaKeyPair, ECDSA_P256_SHA256_FIXED_SIGNING};

    const WEATHERKIT: &[u8] = include_bytes!("fixtures/weatherkit/weather.json");
    const PIRATE: &[u8] = include_bytes!("fixtures/pirate_weather/forecast.json");
    let app = Router::new()
        .route(
            "/wk/weather/de/{lat}/{lon}",
            get(|headers: axum::http::HeaderMap| async move {
                let auth = headers[header::AUTHORIZATION].to_str().unwrap();
                assert!(auth.starts_with("Bearer ey"), "{auth}");
                WEATHERKIT
            }),
        )
        .route("/pw/forecast/test-key/{coords}", get(|| async { PIRATE }));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = Url::parse(&format!("http://{}/", listener.local_addr().unwrap())).unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });

    let pkcs8 = EcdsaKeyPair::generate_pkcs8(
        &ECDSA_P256_SHA256_FIXED_SIGNING,
        &ring::rand::SystemRandom::new(),
    )
    .unwrap();
    let key_pem = format!(
        "-----BEGIN PRIVATE KEY-----\n{}\n-----END PRIVATE KEY-----",
        base64::engine::general_purpose::STANDARD.encode(pkcs8.as_ref())
    );
    let s = TestServer::with_config(|c| {
        c.dev_auth = true;
        // Unreachable: these two fail, the configured ones must still work.
        c.endpoints.open_meteo = Url::parse("http://127.0.0.1:9/").unwrap();
        c.endpoints.bright_sky = Url::parse("http://127.0.0.1:9/").unwrap();
        c.endpoints.weatherkit = base.join("wk/").unwrap();
        c.endpoints.pirate_weather = base.join("pw/").unwrap();
        c.weatherkit = Some(witterung::sources::weatherkit::WeatherKitConfig {
            key_pem,
            key_id: "KEY".into(),
            team_id: "TEAM".into(),
            service_id: "svc".into(),
        });
        c.pirate_weather_key = Some(witterung::config::Secret("test-key".into()));
    });
    let r = s
        .send(
            Request::post("/api/v1/places")
                .header(header::CONTENT_TYPE, "application/json")
                .header("x-witterung-client", "test")
                .body(Body::from(r#"{"name":"Testort","lat":52.97,"lon":10.56}"#))
                .unwrap(),
        )
        .await;
    let id = r.json()["id"].as_i64().unwrap();
    poll_once(&s.app, Timestamp::now()).await;

    let raw = s
        .get(&format!("/api/v1/places/{id}/raw"), Auth::None)
        .await
        .json();
    let sources: Vec<&str> = raw["sources"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["source"].as_str().unwrap())
        .collect();
    assert_eq!(sources, ["pirate_weather", "weatherkit"]);
    assert_eq!(provider(&raw, "weatherkit")["configured"], true);
    assert_eq!(provider(&raw, "open_meteo")["state"]["failures"], 1);
    assert_eq!(raw["attribution"].as_array().unwrap().len(), 4);
}
