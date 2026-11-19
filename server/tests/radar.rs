//! Radar and warning images against a mock DWD GeoServer.

mod common;

use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use axum::extract::{Query, State};
use axum::http::{header, StatusCode};
use axum::response::IntoResponse;
use axum::routing::get;
use axum::Router;
use common::{Auth, TestServer};
use jiff::Timestamp;
use url::Url;

const PNG: &[u8] = b"\x89PNG\r\n\x1a\nfake";
const END: &str = "2030-01-01T14:00:00Z";

#[derive(Clone, Default)]
struct Calls(Arc<AtomicUsize>);

async fn wms(
    State(calls): State<Calls>,
    Query(q): Query<HashMap<String, String>>,
) -> axum::response::Response {
    calls.0.fetch_add(1, Ordering::SeqCst);
    let ok = q.get("REQUEST").map(String::as_str) == Some("GetMap")
        && q.get("CRS").map(String::as_str) == Some("EPSG:3857")
        && q.get("WIDTH").map(String::as_str) == Some("1024");
    let layer = q.get("LAYERS").cloned().unwrap_or_default();
    // Like the DWD: errors come with status 200 as XML.
    if !ok || (layer.contains("Radar") && !q.contains_key("TIME")) {
        return (
            [(header::CONTENT_TYPE, "text/xml")],
            "<ServiceExceptionReport/>",
        )
            .into_response();
    }
    ([(header::CONTENT_TYPE, "image/png")], PNG).into_response()
}

async fn mock_geoserver(calls: Calls) -> Url {
    let caps = format!(
        r#"<Layer><Dimension name="time" default="current" units="ISO8601">2029-12-29T00:00:00.000Z/{}/PT5M</Dimension></Layer>"#,
        END.replace('Z', ".000Z")
    );
    let app = Router::new()
        .route(
            "/dwd/Radar_rv_product_1x1km_ger/ows",
            get(move || async move { caps }),
        )
        .route("/dwd/wms", get(wms))
        .with_state(calls);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = Url::parse(&format!("http://{}/dwd/", listener.local_addr().unwrap())).unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    base
}

async fn server() -> (TestServer, Calls) {
    let calls = Calls::default();
    let base = mock_geoserver(calls.clone()).await;
    let s = TestServer::with_config(|c| {
        c.dev_auth = true;
        c.endpoints.dwd_geoserver = base;
    });
    (s, calls)
}

#[tokio::test]
async fn frames_from_capabilities() {
    let (s, _) = server().await;
    let r = s.get("/api/v1/radar", Auth::None).await.json();
    let frames = r["frames"].as_array().unwrap();
    assert_eq!(frames.len(), 49);
    assert_eq!(frames[48], END);
    assert_eq!(frames[24], "2030-01-01T12:00:00Z");
    assert_eq!(r["now_index"], 24);
    assert_eq!(r["image"]["width"], 1024);
    assert_eq!(r["image"]["bbox"].as_array().unwrap().len(), 4);
    assert_eq!(r["image"]["frame"], "/api/v1/radar/frames/{unix}");
}

#[tokio::test]
async fn frame_images_are_cached() {
    let (s, calls) = server().await;
    let t: Timestamp = "2030-01-01T12:00:00Z".parse().unwrap();
    let path = format!("/api/v1/radar/frames/{}", t.as_second());
    let r = s.get(&path, Auth::None).await;
    assert_eq!(r.status, StatusCode::OK, "{}", r.text());
    assert_eq!(r.header("content-type"), Some("image/png"));
    assert_eq!(r.body, PNG);
    assert!(r.header("cache-control").unwrap().contains("max-age=10800"));
    let before = calls.0.load(Ordering::SeqCst);
    let again = s.get(&path, Auth::None).await;
    assert_eq!(again.body, PNG);
    assert_eq!(
        calls.0.load(Ordering::SeqCst),
        before,
        "second request from cache"
    );

    // Forecast frames expire sooner, times outside the plan do not exist.
    let forecast = format!("/api/v1/radar/frames/{}", t.as_second() + 3600);
    let r = s.get(&forecast, Auth::None).await;
    assert!(r.header("cache-control").unwrap().contains("max-age=240"));
    let r = s
        .get(
            &format!("/api/v1/radar/frames/{}", t.as_second() + 1),
            Auth::None,
        )
        .await;
    assert_eq!(r.status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn warnings_image() {
    let (s, calls) = server().await;
    let r = s.get("/api/v1/radar/warnings", Auth::None).await;
    assert_eq!(r.status, StatusCode::OK, "{}", r.text());
    assert_eq!(r.body, PNG);
    let before = calls.0.load(Ordering::SeqCst);
    s.get("/api/v1/radar/warnings", Auth::None).await;
    assert_eq!(calls.0.load(Ordering::SeqCst), before);
}

#[tokio::test]
async fn xml_instead_of_png_is_an_upstream_error() {
    let calls = Calls::default();
    let base = mock_geoserver(calls).await;
    // A GeoServer path without capabilities or WMS (404 instead of a PNG).
    let s = TestServer::with_config(|c| {
        c.dev_auth = true;
        c.endpoints.dwd_geoserver = base.join("missing/").unwrap();
    });
    let r = s.get("/api/v1/radar", Auth::None).await.json();
    // Capabilities unreachable: frames from the clock.
    assert_eq!(r["frames"].as_array().unwrap().len(), 49);
    let t = r["frames"][24]
        .as_str()
        .unwrap()
        .parse::<Timestamp>()
        .unwrap();
    let r = s
        .get(
            &format!("/api/v1/radar/frames/{}", t.as_second()),
            Auth::None,
        )
        .await;
    assert_eq!(r.status, StatusCode::BAD_GATEWAY, "{}", r.text());
}

#[tokio::test]
async fn needs_auth() {
    let s = TestServer::with_config(|_| {});
    let r = s.get("/api/v1/radar/warnings", Auth::None).await;
    assert_eq!(r.status, StatusCode::UNAUTHORIZED);
}
