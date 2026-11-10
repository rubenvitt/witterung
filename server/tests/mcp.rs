//! MCP endpoint and its OAuth authorization server, end to end: discovery,
//! registration, consent, code exchange, refresh rotation, revocation, and
//! the tools against a local mock upstream.

mod common;

use axum::body::Body;
use axum::http::{header, Request, StatusCode};
use axum::routing::get;
use axum::Router;
use common::{Auth, TestServer};
use jiff::{SignedDuration, Timestamp};
use serde_json::{json, Value};
use url::Url;

const VERIFIER: &str = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
const CHALLENGE: &str = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM";
const REDIRECT: &str = "https://claude.ai/api/mcp/auth_callback";
const ORIGIN: &str = "http://localhost:8080";

const OPEN_METEO: &[u8] = include_bytes!("fixtures/open_meteo/uelzen.json");
const CURRENT: &[u8] = include_bytes!("fixtures/bright_sky/current_weather.json");
const ALERTS: &[u8] = include_bytes!("fixtures/bright_sky/alerts.json");
const RADAR: &[u8] = include_bytes!("fixtures/bright_sky/radar.json");

fn fresh(fixture: &[u8], pointer: &str, hours: i64) -> String {
    let mut v: Value = serde_json::from_slice(fixture).unwrap();
    *v.pointer_mut(pointer).unwrap() = (Timestamp::now() + SignedDuration::from_hours(hours))
        .to_string()
        .into();
    v.to_string()
}

async fn mock_upstreams() -> Url {
    let app = Router::new()
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
                let run = (Timestamp::now() - SignedDuration::from_mins(5)).to_string();
                String::from_utf8_lossy(RADAR).replace(
                    "RADARCOMP::RV::2026-11-09T12:35:00+00:00",
                    &format!("RADARCOMP::RV::{run}"),
                )
            }),
        );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = Url::parse(&format!("http://{}/", listener.local_addr().unwrap())).unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    base
}

async fn server() -> TestServer {
    let base = mock_upstreams().await;
    TestServer::with_config(|c| {
        c.dev_auth = true;
        c.endpoints.open_meteo = base.join("om/").unwrap();
        c.endpoints.bright_sky = base.join("bs/").unwrap();
    })
}

fn form(path: &str, body: &str) -> Request<Body> {
    Request::post(path)
        .header(header::CONTENT_TYPE, "application/x-www-form-urlencoded")
        .body(Body::from(body.to_owned()))
        .unwrap()
}

fn enc(s: &str) -> String {
    url::form_urlencoded::byte_serialize(s.as_bytes()).collect()
}

async fn register(s: &TestServer) -> String {
    let r = s
        .send(
            Request::post("/oauth/register")
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(
                    json!({"client_name": "Claude", "redirect_uris": [REDIRECT]}).to_string(),
                ))
                .unwrap(),
        )
        .await;
    assert_eq!(r.status, StatusCode::CREATED, "{}", r.text());
    assert_eq!(r.json()["token_endpoint_auth_method"], "none");
    r.json()["client_id"].as_str().unwrap().to_owned()
}

/// Runs the authorization request and consent; returns the code.
async fn authorize(s: &TestServer, client_id: &str) -> String {
    let page = s
        .get(
            &format!(
                "/oauth/authorize?response_type=code&client_id={}&redirect_uri={}\
                 &code_challenge={CHALLENGE}&code_challenge_method=S256&state=xyz\
                 &resource={}",
                enc(client_id),
                enc(REDIRECT),
                enc("http://localhost:8080/mcp")
            ),
            Auth::None,
        )
        .await;
    assert_eq!(page.status, StatusCode::OK, "{}", page.text());
    let html = page.text();
    assert!(html.contains("<strong>Claude</strong>"), "{html}");
    assert!(html.contains("claude.ai"));
    let request_id = html
        .split("name=\"request_id\" value=\"")
        .nth(1)
        .and_then(|rest| rest.split('"').next())
        .unwrap()
        .to_owned();
    let mut req = form(
        "/oauth/authorize",
        &format!("request_id={request_id}&decision=allow"),
    );
    req.headers_mut()
        .insert(header::ORIGIN, ORIGIN.parse().unwrap());
    let r = s.send(req).await;
    assert_eq!(r.status, StatusCode::SEE_OTHER, "{}", r.text());
    let location = Url::parse(r.header("location").unwrap()).unwrap();
    assert!(location.as_str().starts_with(REDIRECT));
    let params: std::collections::HashMap<_, _> = location.query_pairs().into_owned().collect();
    assert_eq!(params["state"], "xyz");
    assert_eq!(params["iss"], "http://localhost:8080");
    params["code"].clone()
}

async fn exchange(s: &TestServer, client_id: &str, code: &str) -> common::TestResponse {
    s.send(form(
        "/oauth/token",
        &format!(
            "grant_type=authorization_code&code={}&client_id={}&redirect_uri={}&code_verifier={VERIFIER}",
            enc(code),
            enc(client_id),
            enc(REDIRECT)
        ),
    ))
    .await
}

async fn connect(s: &TestServer) -> (String, Value) {
    let client_id = register(s).await;
    let code = authorize(s, &client_id).await;
    let r = exchange(s, &client_id, &code).await;
    assert_eq!(r.status, StatusCode::OK, "{}", r.text());
    assert_eq!(r.header("cache-control"), Some("no-store"));
    (client_id, r.json())
}

async fn mcp(s: &TestServer, token: &str, body: Value) -> common::TestResponse {
    s.send(
        Request::post("/mcp")
            .header(header::HOST, "witterung.example.org")
            .header(header::CONTENT_TYPE, "application/json")
            .header(header::AUTHORIZATION, format!("Bearer {token}"))
            .body(Body::from(body.to_string()))
            .unwrap(),
    )
    .await
}

async fn tool(s: &TestServer, token: &str, name: &str, arguments: Value) -> Value {
    let r = mcp(
        s,
        token,
        json!({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
               "params": {"name": name, "arguments": arguments}}),
    )
    .await;
    assert_eq!(r.status, StatusCode::OK, "{}", r.text());
    r.json()["result"].clone()
}

#[tokio::test]
async fn discovery_and_challenge() {
    let s = server().await;
    let r = s
        .send(
            Request::post("/mcp")
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await;
    assert_eq!(r.status, StatusCode::UNAUTHORIZED);
    assert_eq!(
        r.header("www-authenticate"),
        Some(
            "Bearer resource_metadata=\"http://localhost:8080/.well-known/oauth-protected-resource\""
        )
    );
    // dev auth and session cookies do not count for /mcp
    assert_eq!(
        mcp(&s, "irgendwas", json!({})).await.header("www-authenticate"),
        Some("Bearer resource_metadata=\"http://localhost:8080/.well-known/oauth-protected-resource\", error=\"invalid_token\"")
    );

    let pr = s
        .get("/.well-known/oauth-protected-resource", Auth::None)
        .await
        .json();
    assert_eq!(pr["resource"], "http://localhost:8080/mcp");
    assert_eq!(pr["authorization_servers"][0], "http://localhost:8080");
    let asm = s
        .get("/.well-known/oauth-authorization-server", Auth::None)
        .await
        .json();
    assert_eq!(
        asm["registration_endpoint"],
        "http://localhost:8080/oauth/register"
    );
    assert_eq!(asm["code_challenge_methods_supported"], json!(["S256"]));
}

#[tokio::test]
async fn registration_is_validated() {
    let s = server().await;
    for (body, error) in [
        (json!({}), "invalid_redirect_uri"),
        (
            json!({"redirect_uris": ["http://evil.example/cb"]}),
            "invalid_redirect_uri",
        ),
        (
            json!({"redirect_uris": [REDIRECT], "grant_types": ["client_credentials"]}),
            "invalid_client_metadata",
        ),
    ] {
        let r = s
            .send(
                Request::post("/oauth/register")
                    .header(header::CONTENT_TYPE, "application/json")
                    .body(Body::from(body.to_string()))
                    .unwrap(),
            )
            .await;
        assert_eq!(r.status, StatusCode::BAD_REQUEST, "{body}");
        assert_eq!(r.json()["error"], error, "{body}");
    }
}

#[tokio::test]
async fn authorize_needs_login_and_valid_request() {
    let s = TestServer::with_config(|_| {});
    let client_id = register(&s).await;
    let url = format!(
        "/oauth/authorize?response_type=code&client_id={}&redirect_uri={}\
         &code_challenge={CHALLENGE}&code_challenge_method=S256",
        enc(&client_id),
        enc(REDIRECT)
    );
    // no session: off to the login, and back here afterwards
    let r = s.get(&url, Auth::None).await;
    assert_eq!(r.status, StatusCode::SEE_OTHER);
    assert!(r
        .header("location")
        .unwrap()
        .starts_with("/auth/login?return_to=%2Foauth%2Fauthorize%3F"));

    // unknown client or foreign redirect URI: a page, never a redirect
    let r = s
        .get(
            "/oauth/authorize?response_type=code&client_id=nope",
            Auth::None,
        )
        .await;
    assert_eq!(r.status, StatusCode::BAD_REQUEST);
    let r = s
        .get(
            &format!(
                "/oauth/authorize?response_type=code&client_id={}&redirect_uri={}",
                enc(&client_id),
                enc("https://evil.example/cb")
            ),
            Auth::None,
        )
        .await;
    assert_eq!(r.status, StatusCode::BAD_REQUEST);

    // without PKCE the client gets an error redirect
    let r = s
        .get(
            &format!(
                "/oauth/authorize?response_type=code&client_id={}&redirect_uri={}",
                enc(&client_id),
                enc(REDIRECT)
            ),
            Auth::None,
        )
        .await;
    assert_eq!(r.status, StatusCode::SEE_OTHER);
    assert!(r
        .header("location")
        .unwrap()
        .contains("error=invalid_request"));
}

#[tokio::test]
async fn consent_is_bound_and_single_use() {
    let s = server().await;
    let client_id = register(&s).await;
    let page = s
        .get(
            &format!(
                "/oauth/authorize?response_type=code&client_id={}&redirect_uri={}\
                 &code_challenge={CHALLENGE}&code_challenge_method=S256",
                enc(&client_id),
                enc(REDIRECT)
            ),
            Auth::None,
        )
        .await
        .text();
    let request_id = page
        .split("name=\"request_id\" value=\"")
        .nth(1)
        .and_then(|rest| rest.split('"').next())
        .unwrap()
        .to_owned();
    // a foreign origin is refused
    let mut req = form(
        "/oauth/authorize",
        &format!("request_id={request_id}&decision=allow"),
    );
    req.headers_mut()
        .insert(header::ORIGIN, "https://evil.example".parse().unwrap());
    assert_eq!(s.send(req).await.status, StatusCode::FORBIDDEN);
    // deny goes back with access_denied
    let r = s
        .send(form(
            "/oauth/authorize",
            &format!("request_id={request_id}&decision=deny"),
        ))
        .await;
    assert_eq!(r.status, StatusCode::SEE_OTHER);
    assert!(r
        .header("location")
        .unwrap()
        .contains("error=access_denied"));
    // and the request is used up
    let r = s
        .send(form(
            "/oauth/authorize",
            &format!("request_id={request_id}&decision=allow"),
        ))
        .await;
    assert_eq!(r.status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn tokens_rotate_and_replays_revoke() {
    let s = server().await;
    let client_id = register(&s).await;
    let code = authorize(&s, &client_id).await;

    // wrong verifier fails (and uses up the code)
    let bad = s
        .send(form(
            "/oauth/token",
            &format!(
                "grant_type=authorization_code&code={}&client_id={}&redirect_uri={}&code_verifier={}",
                enc(&code),
                enc(&client_id),
                enc(REDIRECT),
                "x".repeat(43)
            ),
        ))
        .await;
    assert_eq!(bad.status, StatusCode::BAD_REQUEST);
    assert_eq!(bad.json()["error"], "invalid_grant");

    let code = authorize(&s, &client_id).await;
    let tokens = exchange(&s, &client_id, &code).await.json();
    let access = tokens["access_token"].as_str().unwrap().to_owned();
    let refresh = tokens["refresh_token"].as_str().unwrap().to_owned();
    assert!(access.starts_with("woa_"));
    assert_eq!(tokens["expires_in"], 3600);
    let ping = json!({"jsonrpc": "2.0", "id": 1, "method": "ping"});
    assert_eq!(mcp(&s, &access, ping.clone()).await.status, StatusCode::OK);

    // replaying the code revokes what it produced
    let replay = exchange(&s, &client_id, &code).await;
    assert_eq!(replay.json()["error"], "invalid_grant");
    assert_eq!(
        mcp(&s, &access, ping.clone()).await.status,
        StatusCode::UNAUTHORIZED
    );
    let r = s
        .send(form(
            "/oauth/token",
            &format!("grant_type=refresh_token&refresh_token={refresh}"),
        ))
        .await;
    assert_eq!(r.json()["error"], "invalid_grant");

    // a fresh grant: refresh rotates, reuse of the old refresh token cuts it off
    let code = authorize(&s, &client_id).await;
    let tokens = exchange(&s, &client_id, &code).await.json();
    let refresh = tokens["refresh_token"].as_str().unwrap().to_owned();
    let rotated = s
        .send(form(
            "/oauth/token",
            &format!("grant_type=refresh_token&refresh_token={refresh}"),
        ))
        .await;
    assert_eq!(rotated.status, StatusCode::OK, "{}", rotated.text());
    let new_access = rotated.json()["access_token"].as_str().unwrap().to_owned();
    assert_eq!(
        mcp(&s, &new_access, ping.clone()).await.status,
        StatusCode::OK
    );
    let reuse = s
        .send(form(
            "/oauth/token",
            &format!("grant_type=refresh_token&refresh_token={refresh}"),
        ))
        .await;
    assert_eq!(reuse.json()["error"], "invalid_grant");
    assert_eq!(
        mcp(&s, &new_access, ping).await.status,
        StatusCode::UNAUTHORIZED
    );
}

#[tokio::test]
async fn connections_can_be_listed_and_disconnected() {
    let s = server().await;
    let (client_id, tokens) = connect(&s).await;
    let access = tokens["access_token"].as_str().unwrap();
    let list = s.get("/api/v1/connections", Auth::None).await.json();
    assert_eq!(list[0]["id"], client_id.as_str());
    assert_eq!(list[0]["name"], "Claude");
    let r = s
        .send(
            Request::delete(format!("/api/v1/connections/{}", enc(&client_id)))
                .header("x-witterung-client", "test")
                .body(Body::empty())
                .unwrap(),
        )
        .await;
    assert_eq!(r.status, StatusCode::NO_CONTENT);
    let ping = json!({"jsonrpc": "2.0", "id": 1, "method": "ping"});
    assert_eq!(mcp(&s, access, ping).await.status, StatusCode::UNAUTHORIZED);
    assert_eq!(
        s.get("/api/v1/connections", Auth::None).await.json(),
        json!([])
    );
}

#[tokio::test]
async fn protocol_basics() {
    let s = server().await;
    let (_, tokens) = connect(&s).await;
    let token = tokens["access_token"].as_str().unwrap();

    let init = mcp(
        &s,
        token,
        json!({"jsonrpc": "2.0", "id": "a", "method": "initialize",
               "params": {"protocolVersion": "2025-03-26", "capabilities": {}}}),
    )
    .await
    .json();
    assert_eq!(init["id"], "a");
    assert_eq!(init["result"]["protocolVersion"], "2025-03-26");
    assert_eq!(init["result"]["serverInfo"]["name"], "witterung");
    assert!(init["result"]["instructions"]
        .as_str()
        .unwrap()
        .contains("Konsens"));

    // notifications: 202 without body
    let r = mcp(
        &s,
        token,
        json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
    )
    .await;
    assert_eq!(r.status, StatusCode::ACCEPTED);
    assert!(r.body.is_empty());

    // batch
    let r = mcp(
        &s,
        token,
        json!([{"jsonrpc": "2.0", "id": 1, "method": "ping"},
               {"jsonrpc": "2.0", "id": 2, "method": "nope"}]),
    )
    .await
    .json();
    assert_eq!(r[0]["result"], json!({}));
    assert_eq!(r[1]["error"]["code"], -32601);

    let tools = mcp(
        &s,
        token,
        json!({"jsonrpc": "2.0", "id": 3, "method": "tools/list"}),
    )
    .await
    .json();
    let names: Vec<&str> = tools["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap())
        .collect();
    assert_eq!(
        names,
        [
            "list_places",
            "get_forecast",
            "get_alerts",
            "get_source_status",
            "create_place",
            "update_place",
            "delete_place"
        ]
    );

    // origin check and protocol version header
    let mut req = Request::post("/mcp")
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::AUTHORIZATION, format!("Bearer {token}"))
        .header(header::ORIGIN, "https://evil.example")
        .body(Body::from(r#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#))
        .unwrap();
    assert_eq!(s.send(req).await.status, StatusCode::FORBIDDEN);
    req = Request::post("/mcp")
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::AUTHORIZATION, format!("Bearer {token}"))
        .header("mcp-protocol-version", "1999-01-01")
        .body(Body::from(r#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#))
        .unwrap();
    assert_eq!(s.send(req).await.status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn device_tokens_work_too() {
    let s = server().await;
    let r = s
        .send(
            Request::post("/api/v1/devices")
                .header(header::CONTENT_TYPE, "application/json")
                .header("x-witterung-client", "test")
                .body(Body::from(r#"{"name":"Claude Code"}"#))
                .unwrap(),
        )
        .await;
    assert_eq!(r.status, StatusCode::CREATED, "{}", r.text());
    let token = r.json()["token"].as_str().unwrap().to_owned();
    let result = tool(&s, &token, "list_places", json!({})).await;
    assert_eq!(result["isError"], false);
    assert_eq!(result["structuredContent"]["places"], json!([]));
}

#[tokio::test]
async fn weather_tools() {
    let s = server().await;
    let (_, tokens) = connect(&s).await;
    let t = tokens["access_token"].as_str().unwrap();

    let created = tool(
        &s,
        t,
        "create_place",
        json!({"name": "Uelzen", "lat": 52.97, "lon": 10.56}),
    )
    .await;
    assert_eq!(created["isError"], false, "{created}");
    let id = created["structuredContent"]["place"]["id"]
        .as_i64()
        .unwrap();
    tool(
        &s,
        t,
        "create_place",
        json!({"name": "Hamburg", "lat": 53.55, "lon": 9.99}),
    )
    .await;

    let places = tool(&s, t, "list_places", json!({})).await;
    assert_eq!(
        places["structuredContent"]["places"][0]["name"], "Uelzen",
        "{places}"
    );

    // by name, fresh place: fetched right away
    let f = tool(
        &s,
        t,
        "get_forecast",
        json!({"place": "uelz", "hours": 3, "days": 2}),
    )
    .await;
    assert_eq!(f["isError"], false, "{f}");
    let f = &f["structuredContent"];
    assert_eq!(f["location"]["id"], id);
    assert!(
        f["generated_at"].as_str().unwrap().contains("+01:00")
            || f["generated_at"].as_str().unwrap().contains("+02:00")
    );
    assert!(f["hourly"].as_array().unwrap().len() <= 3);
    assert!(f["daily"].as_array().unwrap().len() <= 2);
    assert!(
        f["nowcast"]["summary"]
            .as_str()
            .unwrap()
            .starts_with("Laut Radar")
            || f["nowcast"]["summary"] == "Keine aktuellen Radardaten.",
        "{f}"
    );
    assert!(f["now"]["observed"]["temp_c"].is_number(), "{f}");
    assert!(!f["alerts"].as_array().unwrap().is_empty(), "{f}");
    assert!(f["attribution"]
        .as_array()
        .unwrap()
        .iter()
        .any(|a| a.as_str().unwrap().contains("Open-Meteo")));
    assert!(!f.to_string().contains("null"));

    // free coordinates
    let f = tool(
        &s,
        t,
        "get_forecast",
        json!({"lat": 52.0, "lon": 10.0, "days": 0}),
    )
    .await;
    assert_eq!(f["isError"], false, "{f}");
    assert_eq!(f["structuredContent"]["location"]["lat"], 52.0);
    assert!(f["structuredContent"]
        .get("daily")
        .is_none_or(|d| d == &json!([])));

    // errors are tool results, not protocol errors
    for (args, needle) in [
        (json!({}), "place oder lat und lon"),
        (json!({"place": "Berlin"}), "Vorhanden: Uelzen, Hamburg"),
        (json!({"place": 1, "lat": 1.0, "lon": 1.0}), "nicht beides"),
        (json!({"place": 1, "hours": 99}), "0 bis 48"),
        (json!({"plaec": 1}), "Unbekanntes Argument: plaec"),
    ] {
        let r = tool(&s, t, "get_forecast", args.clone()).await;
        assert_eq!(r["isError"], true, "{args}");
        let text = r["content"][0]["text"].as_str().unwrap();
        assert!(text.contains(needle), "{args}: {text}");
    }

    let alerts = tool(&s, t, "get_alerts", json!({})).await;
    assert_eq!(alerts["isError"], false, "{alerts}");
    assert_eq!(
        alerts["structuredContent"]["places"]
            .as_array()
            .unwrap()
            .len(),
        2
    );

    let status = tool(&s, t, "get_source_status", json!({})).await;
    assert!(status["structuredContent"]["providers"].is_array());

    let updated = tool(
        &s,
        t,
        "update_place",
        json!({"place": "Hamburg", "name": "HH", "notify": true, "position": 0}),
    )
    .await;
    assert_eq!(
        updated["structuredContent"]["place"]["name"], "HH",
        "{updated}"
    );
    assert_eq!(updated["structuredContent"]["place"]["notify"], true);
    let places = tool(&s, t, "list_places", json!({})).await;
    assert_eq!(places["structuredContent"]["places"][0]["name"], "HH");

    let deleted = tool(&s, t, "delete_place", json!({"place": id})).await;
    assert_eq!(deleted["structuredContent"]["deleted"]["name"], "Uelzen");
    let places = tool(&s, t, "list_places", json!({})).await;
    assert_eq!(
        places["structuredContent"]["places"]
            .as_array()
            .unwrap()
            .len(),
        1
    );

    let unknown = mcp(
        &s,
        t,
        json!({"jsonrpc": "2.0", "id": 9, "method": "tools/call",
               "params": {"name": "rain_dance"}}),
    )
    .await
    .json();
    assert_eq!(unknown["error"]["code"], -32602);
}
