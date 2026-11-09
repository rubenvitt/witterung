//! Polling and the weather API against a local mock upstream: failure
//! isolation, quota/backoff bookkeeping, the aggregated forecast.

mod common;

use axum::body::Body;
use axum::http::{header, Request, StatusCode};
use axum::routing::get;
use axum::Router;
use common::{Auth, TestServer};
use jiff::{SignedDuration, Timestamp};
use serde_json::Value;
use url::Url;
use witterung::poller::poll_once;

const OPEN_METEO: &[u8] = include_bytes!("fixtures/open_meteo/uelzen.json");
const MOSMIX: &[u8] = include_bytes!("fixtures/bright_sky/weather.json");
const CURRENT: &[u8] = include_bytes!("fixtures/bright_sky/current_weather.json");
const ALERTS: &[u8] = include_bytes!("fixtures/bright_sky/alerts.json");
const RADAR: &[u8] = include_bytes!("fixtures/bright_sky/radar.json");

/// The fixture with the timestamp at `pointer` moved to now + `hours`, so
/// age and expiry checks do not depend on when the tests run.
fn fresh(fixture: &[u8], pointer: &str, hours: i64) -> String {
    let mut v: Value = serde_json::from_slice(fixture).unwrap();
    *v.pointer_mut(pointer).unwrap() = (Timestamp::now() + SignedDuration::from_hours(hours))
        .to_string()
        .into();
    v.to_string()
}

async fn serve(app: Router) -> Url {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = Url::parse(&format!("http://{}/", listener.local_addr().unwrap())).unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    base
}

/// Open-Meteo answers with the fixture; Bright Sky `/weather` with HTTP 500,
/// its other endpoints with fixtures.
async fn mock_upstreams() -> Url {
    serve(
        Router::new()
            .route("/om/forecast", get(|| async { OPEN_METEO }))
            .route(
                "/bs/weather",
                get(|| async { (StatusCode::INTERNAL_SERVER_ERROR, "kaputt") }),
            )
            .route(
                "/bs/current_weather",
                get(|| async { fresh(CURRENT, "/weather/timestamp", 0) }),
            )
            .route(
                "/bs/alerts",
                get(|| async { fresh(ALERTS, "/alerts/0/expires", 24) }),
            )
            .route(
                "/bs/radar",
                get(|| async {
                    // Make the fixture's newest radar run 5 minutes old.
                    let run = (Timestamp::now() - SignedDuration::from_mins(5)).to_string();
                    String::from_utf8_lossy(RADAR).replace(
                        "RADARCOMP::RV::2026-11-09T12:35:00+00:00",
                        &format!("RADARCOMP::RV::{run}"),
                    )
                }),
            ),
    )
    .await
}

async fn post_json(s: &TestServer, path: &str, body: &str) -> common::TestResponse {
    s.send(
        Request::post(path)
            .header(header::CONTENT_TYPE, "application/json")
            .header("x-witterung-client", "test")
            .body(Body::from(body.to_owned()))
            .unwrap(),
    )
    .await
}

async fn server_with_place() -> (TestServer, i64) {
    let base = mock_upstreams().await;
    let s = TestServer::with_config(|c| {
        c.dev_auth = true;
        c.endpoints.open_meteo = base.join("om/").unwrap();
        c.endpoints.bright_sky = base.join("bs/").unwrap();
    });
    let r = post_json(
        &s,
        "/api/v1/places",
        r#"{"name":"Testort","lat":52.97,"lon":10.56}"#,
    )
    .await;
    assert_eq!(r.status, StatusCode::CREATED, "{}", r.text());
    let id = r.json()["id"].as_i64().unwrap();
    (s, id)
}

fn provider<'a>(raw: &'a Value, name: &str) -> &'a Value {
    raw["providers"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["provider"] == name)
        .unwrap_or_else(|| panic!("no provider {name}"))
}

fn names(list: &Value, key: &str) -> Vec<String> {
    list.as_array()
        .unwrap()
        .iter()
        .map(|s| s[key].as_str().unwrap().to_owned())
        .collect()
}

#[tokio::test]
async fn failing_source_does_not_break_the_others() {
    let (s, id) = server_with_place().await;
    poll_once(&s.app, Timestamp::now()).await;

    let r = s.get(&format!("/api/v1/places/{id}/raw"), Auth::None).await;
    assert_eq!(r.status, StatusCode::OK, "{}", r.text());
    let raw = r.json();
    assert_eq!(
        names(&raw["sources"], "source"),
        [
            "dwd:alerts",
            "dwd:nowcast",
            "dwd:observation",
            "open_meteo:ecmwf_ifs",
            "open_meteo:gfs",
            "open_meteo:icon_d2",
            "open_meteo:icon_eu"
        ]
    );
    let om = provider(&raw, "open_meteo");
    assert_eq!(om["state"]["failures"], 0);
    assert!(om["quota"]["used"].as_f64().unwrap() > 0.0);
    let bs = provider(&raw, "bright_sky");
    assert_eq!(bs["state"]["failures"], 1);
    assert!(bs["state"]["error"].as_str().unwrap().contains("500"));
    // Failed calls count too; all four Bright Sky feeds share one account.
    assert_eq!(bs["quota"]["used"], 4.0);

    // The aggregated forecast still works and reports the failure.
    let f = s
        .get(&format!("/api/v1/places/{id}/forecast"), Auth::None)
        .await
        .json();
    let mosmix = f["sources"]
        .as_array()
        .unwrap()
        .iter()
        .find(|x| x["provider"] == "bright_sky")
        .unwrap();
    assert_eq!(mosmix["ok"], false);
    assert_eq!(f["alerts"][0]["event"], "DAUERREGEN");
    assert_eq!(f["now"]["observed"]["station"], "Uelzen");
    assert_eq!(f["nowcast"]["points"].as_array().unwrap().len(), 25);
    assert_eq!(f["attribution"].as_array().unwrap().len(), 2);
}

#[tokio::test]
async fn polls_again_only_when_due() {
    let (s, id) = server_with_place().await;
    let t0 = Timestamp::now();
    poll_once(&s.app, t0).await;
    // 30 s later: nothing is due; the failed feed waits for its backoff.
    poll_once(&s.app, t0 + SignedDuration::from_secs(30)).await;
    let raw = s
        .get(&format!("/api/v1/places/{id}/raw"), Auth::None)
        .await
        .json();
    assert_eq!(provider(&raw, "bright_sky")["quota"]["used"], 4.0);
    let om_used = provider(&raw, "open_meteo")["quota"]["used"]
        .as_f64()
        .unwrap();

    // After 1 min the backoff has passed: one more MOSMIX attempt only.
    poll_once(&s.app, t0 + SignedDuration::from_secs(61)).await;
    let raw = s
        .get(&format!("/api/v1/places/{id}/raw"), Auth::None)
        .await
        .json();
    assert_eq!(provider(&raw, "bright_sky")["quota"]["used"], 5.0);
    assert_eq!(provider(&raw, "bright_sky")["state"]["failures"], 2);
    assert_eq!(
        provider(&raw, "open_meteo")["quota"]["used"]
            .as_f64()
            .unwrap(),
        om_used
    );
}

#[tokio::test]
async fn forecast_aggregates_sources() {
    // Fixture hours are fixed in time: build "now" inside them.
    let base = serve(
        Router::new()
            .route("/om/forecast", get(|| async { OPEN_METEO }))
            .route("/bs/weather", get(|| async { MOSMIX })),
    )
    .await;
    let s = TestServer::with_config(|c| {
        c.dev_auth = true;
        c.endpoints.open_meteo = base.join("om/").unwrap();
        c.endpoints.bright_sky = base.join("bs/").unwrap();
    });
    let r = post_json(
        &s,
        "/api/v1/places",
        r#"{"name":"Testort","lat":52.97,"lon":10.56}"#,
    )
    .await;
    let id = r.json()["id"].as_i64().unwrap();
    poll_once(&s.app, Timestamp::now()).await;
    let f = s
        .get(&format!("/api/v1/places/{id}/forecast"), Auth::None)
        .await
        .json();
    assert_eq!(f["location"]["name"], "Testort");
    // 4 Open-Meteo models + MOSMIX delivered; DWD feeds failed (404).
    let ok: Vec<String> = f["sources"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|s| s["ok"] == true)
        .map(|s| s["source"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(ok.len(), 5, "{ok:?}");
    // The fixtures are from 9 Nov 2026; rows only exist if "now" is within.
    for row in f["hourly"].as_array().unwrap() {
        let n = row["n_sources"].as_u64().unwrap();
        assert_eq!(row["by_source"].as_object().unwrap().len() as u64, n);
        let spread = &row["spread"]["temp_c"];
        let t = row["consensus"]["temp_c"].as_f64().unwrap();
        assert!(spread["min"].as_f64().unwrap() <= t && t <= spread["max"].as_f64().unwrap());
    }
}

#[tokio::test]
async fn places_crud_and_validation() {
    let (s, id) = server_with_place().await;
    let r = post_json(&s, "/api/v1/places", r#"{"name":"x","lat":95,"lon":10}"#).await;
    assert_eq!(r.status, StatusCode::BAD_REQUEST);
    let second = post_json(
        &s,
        "/api/v1/places",
        r#"{"name":"Zweiter","lat":53.0,"lon":10.0}"#,
    )
    .await
    .json()["id"]
        .as_i64()
        .unwrap();
    assert_eq!(
        s.get("/api/v1/places/999/raw", Auth::None).await.status,
        StatusCode::NOT_FOUND
    );

    let patch = |path: String, body: &'static str| {
        Request::patch(path)
            .header(header::CONTENT_TYPE, "application/json")
            .header("x-witterung-client", "test")
            .body(Body::from(body))
            .unwrap()
    };
    let r = s
        .send(patch(
            format!("/api/v1/places/{second}"),
            r#"{"name":"Neu","notify":true,"position":0}"#,
        ))
        .await;
    assert_eq!(r.status, StatusCode::OK, "{}", r.text());
    assert_eq!(r.json()["notify"], true);
    let list = s.get("/api/v1/places", Auth::None).await.json();
    assert_eq!(names(&list, "name"), ["Neu", "Testort"]);

    let del = s
        .send(
            Request::delete(format!("/api/v1/places/{id}"))
                .header("x-witterung-client", "test")
                .body(Body::empty())
                .unwrap(),
        )
        .await;
    assert_eq!(del.status, StatusCode::NO_CONTENT);
    assert_eq!(
        names(&s.get("/api/v1/places", Auth::None).await.json(), "name"),
        ["Neu"]
    );
}

#[tokio::test]
async fn current_location_is_snapped_fetched_and_hidden_from_places() {
    let (s, _) = server_with_place().await;
    let r = s
        .get("/api/v1/forecast?lat=52.9656&lon=10.5594", Auth::None)
        .await;
    assert_eq!(r.status, StatusCode::OK, "{}", r.text());
    let f = r.json();
    assert_eq!(f["location"]["kind"], "current");
    assert_eq!(f["location"]["lat"], 52.96);
    assert_eq!(f["location"]["lon"], 10.56);
    // Fetched on first use, without waiting for the poller.
    assert!(!f["sources"].as_array().unwrap().is_empty());
    // A nearby point hits the same place.
    let g = s
        .get("/api/v1/forecast?lat=52.961&lon=10.561", Auth::None)
        .await
        .json();
    assert_eq!(g["location"]["id"], f["location"]["id"]);
    assert_eq!(
        s.get("/api/v1/places", Auth::None)
            .await
            .json()
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

#[tokio::test]
async fn health_status_radar() {
    let (s, _) = server_with_place().await;
    poll_once(&s.app, Timestamp::now()).await;
    let h = s.get("/health", Auth::None).await.json();
    assert_eq!(h["status"], "degraded", "MOSMIX fails in this mock");
    assert_eq!(h["sources"].as_array().unwrap().len(), 7);
    let st = s.get("/api/v1/status", Auth::None).await.json();
    assert_eq!(st["providers"].as_array().unwrap().len(), 7);
    let radar = s.get("/api/v1/radar", Auth::None).await.json();
    assert_eq!(radar["frames"].as_array().unwrap().len(), 49);
    assert_eq!(radar["layer"], "dwd:Radar_rv_product_1x1km_ger");
}

#[tokio::test]
async fn credential_sources_poll_when_configured() {
    use base64::Engine;
    use ring::signature::{EcdsaKeyPair, ECDSA_P256_SHA256_FIXED_SIGNING};

    const WEATHERKIT: &[u8] = include_bytes!("fixtures/weatherkit/weather.json");
    const PIRATE: &[u8] = include_bytes!("fixtures/pirate_weather/forecast.json");
    let base = serve(
        Router::new()
            .route(
                "/wk/weather/de/{lat}/{lon}",
                get(|headers: axum::http::HeaderMap| async move {
                    let auth = headers[header::AUTHORIZATION].to_str().unwrap();
                    assert!(auth.starts_with("Bearer ey"), "{auth}");
                    WEATHERKIT
                }),
            )
            .route("/pw/forecast/test-key/{coords}", get(|| async { PIRATE })),
    )
    .await;

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
        // Unreachable: these fail, the configured ones must still work.
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
    let r = post_json(
        &s,
        "/api/v1/places",
        r#"{"name":"Testort","lat":52.97,"lon":10.56}"#,
    )
    .await;
    let id = r.json()["id"].as_i64().unwrap();
    poll_once(&s.app, Timestamp::now()).await;

    let raw = s
        .get(&format!("/api/v1/places/{id}/raw"), Auth::None)
        .await
        .json();
    assert_eq!(
        names(&raw["sources"], "source"),
        ["pirate_weather", "weatherkit"]
    );
    assert_eq!(provider(&raw, "weatherkit")["configured"], true);
    assert_eq!(provider(&raw, "open_meteo")["state"]["failures"], 1);
    let f = s
        .get(&format!("/api/v1/places/{id}/forecast"), Auth::None)
        .await
        .json();
    assert_eq!(f["attribution"].as_array().unwrap().len(), 4);
}
