//! Live-Aktivitäten: Anmeldung der App und Start, Update, Ende über einen
//! nachgebauten APNs-Server.

mod common;

use std::sync::{Arc, Mutex};

use axum::body::Body;
use axum::extract::Path;
use axum::http::{header, HeaderMap, Request, StatusCode};
use axum::routing::post;
use axum::{Json, Router};
use base64::Engine;
use common::TestServer;
use jiff::{SignedDuration, Timestamp};
use ring::signature::{EcdsaKeyPair, ECDSA_P256_SHA256_FIXED_SIGNING};
use serde_json::{json, Value};
use url::Url;
use witterung::db;

const START_TOKEN: &str = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";
const ACTIVITY_TOKEN: &str = "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2";
/// APNs kennt dieses Token nicht mehr.
const GONE_TOKEN: &str = "dead0000dead0000dead0000dead0000dead0000";

#[derive(Debug, Clone)]
struct Sent {
    token: String,
    sandbox: bool,
    headers: HeaderMap,
    body: Value,
}

type Log = Arc<Mutex<Vec<Sent>>>;

async fn mock_apns(log: Log) -> Url {
    let handler = move |sandbox: bool| {
        let log = log.clone();
        post(
            move |Path(token): Path<String>, headers: HeaderMap, Json(body): Json<Value>| {
                let log = log.clone();
                async move {
                    let gone = token == GONE_TOKEN;
                    log.lock().unwrap().push(Sent {
                        token,
                        sandbox,
                        headers,
                        body,
                    });
                    if gone {
                        (StatusCode::GONE, Json(json!({"reason": "Unregistered"})))
                    } else {
                        (StatusCode::OK, Json(json!({})))
                    }
                }
            },
        )
    };
    let app = Router::new()
        .route("/3/device/{token}", handler(false))
        .route("/sandbox/3/device/{token}", handler(true));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = Url::parse(&format!("http://{}/", listener.local_addr().unwrap())).unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    base
}

fn key_pem() -> String {
    let pkcs8 = EcdsaKeyPair::generate_pkcs8(
        &ECDSA_P256_SHA256_FIXED_SIGNING,
        &ring::rand::SystemRandom::new(),
    )
    .unwrap();
    format!(
        "-----BEGIN PRIVATE KEY-----\n{}\n-----END PRIVATE KEY-----",
        base64::engine::general_purpose::STANDARD.encode(pkcs8.as_ref())
    )
}

struct Setup {
    s: TestServer,
    log: Log,
    token: String,
    place: i64,
}

async fn setup() -> Setup {
    let log: Log = Default::default();
    let base = mock_apns(log.clone()).await;
    let s = TestServer::with_config(|c| {
        c.endpoints.apns = base.clone();
        c.endpoints.apns_sandbox = base.join("sandbox/").unwrap();
        c.apns = Some(witterung::live::ApnsConfig {
            key_pem: key_pem(),
            key_id: "KEYID".into(),
            team_id: "TEAM".into(),
            topic: "dev.rubeen.witterung".into(),
        });
    });
    let secret = s.app.config().session_secret.clone();
    let (token, place) = s
        .app
        .blocking(move |c| {
            let (token, _) = witterung::auth::device::issue_token(c, &secret, "iPhone", None, 0)?;
            let place = db::insert_place(c, "Uelzen", 52.97, 10.56, 0)?;
            Ok((token, place.id))
        })
        .await
        .unwrap();
    Setup {
        s,
        log,
        token,
        place,
    }
}

impl Setup {
    async fn call(&self, method: &str, path: &str, body: Value) -> common::TestResponse {
        self.s
            .send(
                Request::builder()
                    .method(method)
                    .uri(path)
                    .header(header::HOST, "witterung.example.org")
                    .header(header::AUTHORIZATION, format!("Bearer {}", self.token))
                    .header(header::CONTENT_TYPE, "application/json")
                    .body(Body::from(body.to_string()))
                    .unwrap(),
            )
            .await
    }

    /// Radar: `values` in 5-min-Schritten ab `start`.
    async fn nowcast(&self, start: Timestamp, values: &[f64]) {
        let points: Vec<Value> = values
            .iter()
            .enumerate()
            .map(|(i, v)| {
                json!({"at": start + SignedDuration::from_mins(5 * i as i64), "precip_mm_h": v})
            })
            .collect();
        let data = json!({"source": "bright_sky:radar", "at": start, "points": points}).to_string();
        let (place, at) = (self.place, Timestamp::now().as_millisecond());
        self.s
            .app
            .blocking(move |c| db::save_snapshot(c, place, "dwd:nowcast", at, &data))
            .await
            .unwrap();
    }

    fn take(&self) -> Vec<Sent> {
        std::mem::take(&mut *self.log.lock().unwrap())
    }
}

#[tokio::test]
async fn start_update_end() {
    let t = setup().await;
    let now = Timestamp::now();

    let r = t
        .call(
            "PUT",
            "/api/v1/live-activities/registration",
            json!({"start_token": START_TOKEN, "place_id": t.place}),
        )
        .await;
    assert_eq!(r.status, StatusCode::OK, "{}", r.text());
    assert_eq!(r.json(), json!({"apns": true}));

    // Trocken: nichts.
    t.nowcast(now, &[0.0; 24]).await;
    witterung::live::evaluate(&t.s.app, now).await.unwrap();
    assert!(t.take().is_empty());

    // Regen in 20 min: Start über das Push-to-Start-Token.
    let mut rain = vec![0.0; 4];
    rain.extend([1.0, 2.0, 0.0, 0.0]);
    t.nowcast(now, &rain).await;
    witterung::live::evaluate(&t.s.app, now).await.unwrap();
    let sent = t.take();
    assert_eq!(sent.len(), 1, "{sent:?}");
    let start = &sent[0];
    assert_eq!(start.token, START_TOKEN);
    assert!(!start.sandbox);
    assert_eq!(start.headers["apns-push-type"], "liveactivity");
    assert_eq!(
        start.headers["apns-topic"],
        "dev.rubeen.witterung.push-type.liveactivity"
    );
    assert_eq!(start.headers["apns-priority"], "10");
    assert!(start.headers["authorization"]
        .to_str()
        .unwrap()
        .starts_with("bearer ey"));
    let aps = &start.body["aps"];
    assert_eq!(aps["event"], "start");
    assert_eq!(aps["attributes-type"], "WeatherActivityAttributes");
    assert_eq!(aps["attributes"]["placeName"], "Uelzen");
    assert_eq!(aps["content-state"]["kind"], "rain_soon");
    assert_eq!(aps["content-state"]["peakMmH"], 2.0);
    assert!(aps["alert"]["title"]
        .as_str()
        .unwrap()
        .starts_with("Uelzen: Regen in"));

    // Derselbe Schauer startet kein zweites Mal (auch wenn die App sich nicht meldet).
    witterung::live::evaluate(&t.s.app, now + SignedDuration::from_mins(1))
        .await
        .unwrap();
    assert!(t.take().is_empty());

    // Die App meldet die Aktivität: ab jetzt Updates über ihr Token.
    let r = t
        .call(
            "PUT",
            "/api/v1/live-activities/7C1D5E4A-0B8F-4C51-9E0B-2B1D0A6E3F11",
            json!({"token": ACTIVITY_TOKEN, "place_id": t.place}),
        )
        .await;
    assert_eq!(r.status, StatusCode::NO_CONTENT, "{}", r.text());
    let later = now + SignedDuration::from_mins(2);
    witterung::live::evaluate(&t.s.app, later).await.unwrap();
    let sent = t.take();
    assert_eq!(sent.len(), 1, "{sent:?}");
    assert_eq!(sent[0].token, ACTIVITY_TOKEN);
    assert_eq!(sent[0].body["aps"]["event"], "update");
    assert!(sent[0].body["aps"].get("attributes").is_none());

    // Nichts geändert: kein Update.
    witterung::live::evaluate(&t.s.app, later + SignedDuration::from_mins(1))
        .await
        .unwrap();
    assert!(t.take().is_empty());

    // Es regnet: Zustandswechsel mit Hinweis.
    let raining = now + SignedDuration::from_mins(21);
    witterung::live::evaluate(&t.s.app, raining).await.unwrap();
    let sent = t.take();
    assert_eq!(sent.len(), 1, "{sent:?}");
    assert_eq!(sent[0].body["aps"]["content-state"]["kind"], "raining");
    assert_eq!(sent[0].headers["apns-priority"], "10");
    assert!(sent[0].body["aps"]["alert"].is_object());

    // Vorbei: Ende, Aktivität vergessen.
    witterung::live::evaluate(&t.s.app, now + SignedDuration::from_mins(31))
        .await
        .unwrap();
    let sent = t.take();
    assert_eq!(sent.len(), 1, "{sent:?}");
    assert_eq!(sent[0].body["aps"]["event"], "end");
    assert_eq!(sent[0].token, ACTIVITY_TOKEN);
    witterung::live::evaluate(&t.s.app, now + SignedDuration::from_mins(32))
        .await
        .unwrap();
    assert!(t.take().is_empty());
}

#[tokio::test]
async fn dead_tokens_are_forgotten_and_sandbox_is_separate() {
    let t = setup().await;
    let now = Timestamp::now();
    t.nowcast(now, &[0.0, 0.0, 1.0, 1.0]).await;
    let r = t
        .call(
            "PUT",
            "/api/v1/live-activities/registration",
            json!({"start_token": GONE_TOKEN, "place_id": t.place, "sandbox": true}),
        )
        .await;
    assert_eq!(r.status, StatusCode::OK, "{}", r.text());
    witterung::live::evaluate(&t.s.app, now).await.unwrap();
    let sent = t.take();
    assert_eq!(sent.len(), 1, "{sent:?}");
    assert!(sent[0].sandbox);
    // Token vergessen: kein zweiter Versuch.
    witterung::live::evaluate(&t.s.app, now).await.unwrap();
    assert!(t.take().is_empty());
    let regs = t.s.app.blocking(db::live_registrations).await.unwrap();
    assert_eq!(regs[0].start_token, None);
    assert!(regs[0].sandbox);
}

#[tokio::test]
async fn validation_and_switching_off() {
    let t = setup().await;
    let bad = t
        .call(
            "PUT",
            "/api/v1/live-activities/registration",
            json!({"start_token": "kein token"}),
        )
        .await;
    assert_eq!(bad.status, StatusCode::BAD_REQUEST);
    let unknown = t
        .call(
            "PUT",
            "/api/v1/live-activities/registration",
            json!({"place_id": 999}),
        )
        .await;
    assert_eq!(unknown.status, StatusCode::BAD_REQUEST);

    let ok = t
        .call(
            "PUT",
            "/api/v1/live-activities/abc",
            json!({"token": ACTIVITY_TOKEN, "place_id": t.place}),
        )
        .await;
    assert_eq!(ok.status, StatusCode::NO_CONTENT, "{}", ok.text());
    let off = t
        .call("DELETE", "/api/v1/live-activities/registration", json!({}))
        .await;
    assert_eq!(off.status, StatusCode::NO_CONTENT);
    let device = t.s.app.blocking(db::list_devices).await.unwrap()[0].id;
    let left =
        t.s.app
            .blocking(move |c| db::live_activities(c, device))
            .await
            .unwrap();
    assert!(left.is_empty());
}

#[tokio::test]
async fn only_with_device_token() {
    let s = TestServer::with_config(|c| c.dev_auth = true);
    let r = s
        .send(
            Request::put("/api/v1/live-activities/registration")
                .header(header::CONTENT_TYPE, "application/json")
                .header("x-witterung-client", "test")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await;
    assert_eq!(r.status, StatusCode::FORBIDDEN, "{}", r.text());
}
