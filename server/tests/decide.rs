//! `POST /api/v1/decide` and the push gate against a mock Jev upstream.

mod common;

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use axum::body::Body;
use axum::extract::State;
use axum::http::{header, HeaderMap, Request, StatusCode};
use axum::routing::post;
use axum::{Json, Router};
use common::TestServer;
use serde_json::{json, Map, Value};
use url::Url;
use witterung::config::Secret;
use witterung::decide::JevConfig;

#[derive(Clone, Default)]
struct Mock {
    calls: Arc<AtomicUsize>,
    last: Arc<std::sync::Mutex<Option<Value>>>,
}

fn choice(criteria: &Value, pick: &str) -> Value {
    let keys: Vec<&String> = criteria.as_object().unwrap().keys().collect();
    let pick = if keys.iter().any(|k| *k == pick) {
        pick.to_owned()
    } else {
        keys[0].clone()
    };
    let probabilities: Map<String, Value> = keys
        .iter()
        .map(|k| {
            (
                (*k).clone(),
                json!(if **k == pick {
                    0.8
                } else {
                    0.2 / (keys.len() - 1).max(1) as f64
                }),
            )
        })
        .collect();
    json!({"type": "choice", "choice": pick, "confidence": 0.74, "probabilities": probabilities})
}

/// Answers every question it gets; checks the bearer key, records the request.
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
    let mut answers = Map::new();
    for (name, q) in body["questions"].as_object().unwrap() {
        let answer = match name.as_str() {
            "focus" => choice(&q["criteria"], "walk"),
            "mode" => choice(&q["criteria"], "tonight"),
            "sections" => choice(&q["criteria"], "tonight"),
            "window" => choice(&q["criteria"], "w1"),
            "urgency" => json!({"type": "score", "score": 2.2, "confidence": 0.6}),
            "notify" => json!({"type": "noul", "noul": 0.1}),
            _ => json!({"type": "refusal"}),
        };
        answers.insert(name.clone(), answer);
    }
    (
        StatusCode::OK,
        Json(
            json!({"model": "jev-1.13.0", "answers": answers, "usage": {"input_tokens": 300, "output_tokens": 40}}),
        ),
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
        "state": {"place": "Uelzen", "localTime": "Mo 19:00", "tempC": 8},
        "options": {
            "rainSoon": "Regen in 25 Minuten. ab 13:25. Grund: Regenradar des DWD",
            "walk": "Gassi-Fenster 17–22 Uhr. trocken, um 7°. Grund: Längste trockene Lücke"
        },
        "windows": {"w0": "17–19 Uhr, trocken, 7°", "w1": "20–22 Uhr, trocken, 5°"}
    })
}

#[tokio::test]
async fn asks_all_questions_once_and_caches() {
    let (s, mock) = server(Some("jev-test")).await;
    let r = decide(&s, request()).await;
    assert_eq!(r.status, StatusCode::OK, "{}", r.text());
    let d = r.json();
    assert_eq!(d["model"], "jev-1.13.0");
    assert_eq!(d["focus"]["choice"], "walk");
    assert_eq!(d["focus"]["probabilities"]["walk"], 0.8);
    assert_eq!(d["mode"]["choice"], "tonight");
    assert_eq!(d["sections"]["choice"], "tonight");
    assert_eq!(d["window"]["choice"], "w1");
    assert_eq!(d["urgency"]["score"], 2.2);

    // The questions are the server's, options, windows and state the app's.
    let sent = mock.last.lock().unwrap().clone().unwrap();
    assert_eq!(sent["model"], "jev-latest");
    assert_eq!(sent["state"]["place"], "Uelzen");
    let q = sent["questions"].as_object().unwrap();
    let mut names: Vec<&str> = q.keys().map(String::as_str).collect();
    names.sort();
    assert_eq!(names, ["focus", "mode", "sections", "urgency", "window"]);

    // Same situation: answered from the cache.
    let again = decide(&s, request()).await;
    assert_eq!(again.json(), d);
    assert_eq!(mock.calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn single_hint_skips_ranking() {
    let (s, mock) = server(Some("jev-test")).await;
    let r = decide(
        &s,
        json!({"state": {"tempC": 8}, "options": {"calm": "Ruhiges Wetter"}}),
    )
    .await;
    assert_eq!(r.status, StatusCode::OK, "{}", r.text());
    let d = r.json();
    assert!(d["focus"].is_null());
    assert!(d["window"].is_null());
    assert_eq!(d["mode"]["choice"], "tonight");
    let sent = mock.last.lock().unwrap().clone().unwrap();
    assert!(sent["questions"].get("focus").is_none());
}

#[tokio::test]
async fn without_key_it_is_unavailable() {
    let (s, mock) = server(None).await;
    let r = decide(&s, request()).await;
    assert_eq!(r.status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(r.json()["error"]["code"], "unavailable");
    assert_eq!(mock.calls.load(Ordering::SeqCst), 0);
    assert_eq!(
        witterung::decide::notify_probability(&s.app, json!({"a": 1})).await,
        None
    );
}

#[tokio::test]
async fn upstream_errors_and_bad_input() {
    let (s, _) = server(Some("falscher-schlüssel")).await;
    let r = decide(&s, request()).await;
    assert_eq!(r.status, StatusCode::BAD_GATEWAY);
    assert_eq!(r.json()["error"]["code"], "upstream");
    // Push gate fails open.
    assert_eq!(
        witterung::decide::notify_probability(&s.app, json!({"a": 1})).await,
        None
    );

    let (s, mock) = server(Some("jev-test")).await;
    let none = json!({"state": {"a": 1}, "options": {}});
    assert_eq!(decide(&s, none).await.status, StatusCode::BAD_REQUEST);
    let bad_key = json!({"state": {"a": 1}, "options": {"a b": "x", "c": "y"}});
    assert_eq!(decide(&s, bad_key).await.status, StatusCode::BAD_REQUEST);
    assert_eq!(mock.calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn push_gate_asks_a_yes_no_question() {
    let (s, mock) = server(Some("jev-test")).await;
    let msg = witterung::push::Message {
        title: "Uelzen: Regen in 18 min".into(),
        message: "Ab 13:20 leichter Regen.".into(),
        priority: 3,
        tags: vec![],
        critical: false,
    };
    let now: jiff::Timestamp = "2026-11-16T22:30:00Z".parse().unwrap();
    let state = witterung::push::push_state("Uelzen", &msg, now);
    assert_eq!(state["localTime"], "Monday 23:30");
    let p = witterung::decide::notify_probability(&s.app, state).await;
    assert_eq!(p, Some(0.1));
    let sent = mock.last.lock().unwrap().clone().unwrap();
    assert_eq!(sent["questions"]["notify"]["type"], "noul");
}

#[tokio::test]
async fn needs_login() {
    let (s, _) = server(Some("jev-test")).await;
    let s2 = TestServer::with_config(|c| c.jev = s.app.config().jev.clone());
    let r = decide(&s2, request()).await;
    assert_eq!(r.status, StatusCode::UNAUTHORIZED);
}
