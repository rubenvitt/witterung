//! `POST /api/v1/decide` against a mock Jev upstream.

mod common;

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use axum::body::Body;
use axum::extract::State;
use axum::http::{header, HeaderMap, Request, StatusCode};
use axum::routing::post;
use axum::{Json, Router};
use common::TestServer;
use serde_json::{json, Value};
use url::Url;
use witterung::config::Secret;
use witterung::decide::JevConfig;

#[derive(Clone, Default)]
struct Mock {
    calls: Arc<AtomicUsize>,
    last: Arc<std::sync::Mutex<Option<Value>>>,
}

/// Picks `walk` if offered, checks the bearer key, records the request.
async fn jev(
    State(mock): State<Mock>,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> (StatusCode, Json<Value>) {
    mock.calls.fetch_add(1, Ordering::SeqCst);
    *mock.last.lock().unwrap() = Some(body.clone());
    if headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        != Some("Bearer jev-test")
    {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"error": {"code": 401, "message": "bad key"}})),
        );
    }
    let options = body["questions"]["focus"]["criteria"].as_object().unwrap();
    let choice = if options.contains_key("walk") {
        "walk"
    } else {
        options.keys().next().unwrap()
    };
    let probabilities: serde_json::Map<String, Value> = options
        .keys()
        .map(|k| {
            (
                k.clone(),
                json!(if k == choice {
                    0.8
                } else {
                    0.2 / (options.len() - 1) as f64
                }),
            )
        })
        .collect();
    (
        StatusCode::OK,
        Json(json!({
            "model": "jev-1.13.0",
            "answers": {"focus": {"type": "choice", "choice": choice, "confidence": 0.74, "probabilities": probabilities}},
            "usage": {"input_tokens": 300, "output_tokens": 40}
        })),
    )
}

async fn server(key: Option<&str>) -> (TestServer, Mock) {
    let mock = Mock::default();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = Url::parse(&format!(
        "http://{}/v1/systemone",
        listener.local_addr().unwrap()
    ))
    .unwrap();
    let app = Router::new()
        .route("/v1/systemone", post(jev))
        .with_state(mock.clone());
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let key = key.map(str::to_owned);
    let s = TestServer::with_config(|c| {
        c.dev_auth = true;
        c.jev = key.map(|k| JevConfig {
            key: Secret(k),
            url,
            model: "jev-latest".into(),
        });
    });
    (s, mock)
}

async fn decide(s: &TestServer, body: Value) -> common::TestResponse {
    s.send(
        Request::post("/api/v1/decide")
            .header(header::CONTENT_TYPE, "application/json")
            .header("x-witterung-client", "test")
            .body(Body::from(body.to_string()))
            .unwrap(),
    )
    .await
}

fn request() -> Value {
    json!({
        "state": {"ort": "Uelzen", "zeit": "Mo 13:00", "temp_c": 8},
        "options": {
            "rainSoon": "Regen in 25 Minuten. ab 13:25. Grund: Regenradar des DWD",
            "walk": "Gassi-Fenster 17–22 Uhr. trocken, um 7°. Grund: Längste trockene Lücke"
        }
    })
}

#[tokio::test]
async fn asks_jev_once_and_caches() {
    let (s, mock) = server(Some("jev-test")).await;
    let r = decide(&s, request()).await;
    assert_eq!(r.status, StatusCode::OK, "{}", r.text());
    let d = r.json();
    assert_eq!(d["choice"], "walk");
    assert_eq!(d["probabilities"]["walk"], 0.8);
    assert_eq!(d["confidence"], 0.74);
    assert_eq!(d["model"], "jev-1.13.0");

    // The question is the server's, the options and state are the app's.
    let sent = mock.last.lock().unwrap().clone().unwrap();
    assert_eq!(sent["model"], "jev-latest");
    assert_eq!(sent["questions"]["focus"]["type"], "choice");
    assert_eq!(sent["state"]["ort"], "Uelzen");
    assert!(sent["questions"]["focus"]["instructions"]
        .as_str()
        .unwrap()
        .contains("dog"));

    // Same situation: answered from the cache.
    let again = decide(&s, request()).await;
    assert_eq!(again.json(), d);
    assert_eq!(mock.calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn without_key_it_is_unavailable() {
    let (s, mock) = server(None).await;
    let r = decide(&s, request()).await;
    assert_eq!(r.status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(r.json()["error"]["code"], "unavailable");
    assert_eq!(mock.calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn upstream_errors_and_bad_input() {
    let (s, _) = server(Some("falscher-schlüssel")).await;
    let r = decide(&s, request()).await;
    assert_eq!(r.status, StatusCode::BAD_GATEWAY);
    assert_eq!(r.json()["error"]["code"], "upstream");

    let (s, mock) = server(Some("jev-test")).await;
    let one = json!({"state": {"a": 1}, "options": {"walk": "Gassi"}});
    assert_eq!(decide(&s, one).await.status, StatusCode::BAD_REQUEST);
    let bad_key = json!({"state": {"a": 1}, "options": {"a b": "x", "c": "y"}});
    assert_eq!(decide(&s, bad_key).await.status, StatusCode::BAD_REQUEST);
    assert_eq!(mock.calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn needs_login() {
    let (s, _) = server(Some("jev-test")).await;
    let s2 = TestServer::with_config(|c| c.jev = s.app.config().jev.clone());
    let r = decide(&s2, request()).await;
    assert_eq!(r.status, StatusCode::UNAUTHORIZED);
}
