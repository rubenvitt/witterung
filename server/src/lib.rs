//! Witterung server: login, health, and (from M1) the weather API.

pub mod api;
pub mod app;
pub mod auth;
pub mod backup;
pub mod config;
pub mod db;
pub mod error;
pub mod forecast;
pub mod healthcheck;
pub mod poller;
pub mod push;
pub mod quota;
pub mod sources;

use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::{Html, IntoResponse, Redirect, Response};
use axum::routing::get;
use axum::Router;
use axum::{middleware, Json};
use serde_json::{json, Value};

pub use app::App;
pub use config::Config;

use auth::middleware::{browser_principal, require_auth};
use auth::Principal;
use error::AppResult;

/// Builds the application and its router.
pub fn build(config: Config, http: reqwest::Client) -> anyhow::Result<(App, Router)> {
    let app = App::open(config, http)?;
    let api = Router::new()
        .route("/api/v1/me", get(me))
        .route(
            "/api/v1/places",
            get(api::list_places).post(api::create_place),
        )
        .route(
            "/api/v1/places/{id}",
            axum::routing::patch(api::update_place).delete(api::delete_place),
        )
        .route("/api/v1/places/{id}/raw", get(api::raw))
        .route("/api/v1/places/{id}/forecast", get(api::place_forecast))
        .route("/api/v1/forecast", get(api::location_forecast))
        .route("/api/v1/status", get(api::status))
        .route("/api/v1/radar", get(api::radar))
        .route("/api/v1/devices", get(api::list_devices))
        .route(
            "/api/v1/settings/notifications",
            get(push::get_settings).put(push::put_settings),
        )
        .route(
            "/api/v1/settings/notifications/test",
            axum::routing::post(push::test),
        )
        .route(
            "/api/v1/devices/{id}",
            axum::routing::delete(api::delete_device),
        )
        .route_layer(middleware::from_fn_with_state(app.clone(), require_auth));
    let router = Router::new()
        .route("/", get(index))
        .route("/health", get(health))
        .merge(auth::routes::routes())
        .merge(auth::device::routes())
        .merge(api)
        .with_state(app.clone());
    Ok((app, router))
}

/// Runs the server until SIGTERM or Ctrl-C.
pub async fn run(config: Config) -> anyhow::Result<()> {
    let bind = config.bind;
    let http = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(20))
        .user_agent(concat!("witterung/", env!("CARGO_PKG_VERSION")))
        .build()?;
    let (app, router) = build(config, http)?;
    poller::spawn(app);
    let listener = tokio::net::TcpListener::bind(bind).await?;
    tracing::info!(%bind, "listening");
    axum::serve(listener, router)
        .with_graceful_shutdown(shutdown_signal())
        .await?;
    Ok(())
}

async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let term = async {
        if let Ok(mut s) = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            s.recv().await;
        }
    };
    #[cfg(not(unix))]
    let term = std::future::pending::<()>();
    tokio::select! { _ = ctrl_c => {}, _ = term => {} }
}

/// Public health: liveness plus per-source state (no place data). `status`
/// is `degraded` when a configured source delivered nothing for 3 h.
async fn health(State(app): State<App>) -> AppResult<Json<Value>> {
    let config = app.config().clone();
    let now = app::now_ms();
    let sources = app
        .blocking(move |c| {
            let places = db::list_places(c)?;
            let mut out = Vec::new();
            for p in poller::Provider::ALL {
                let states: Vec<db::FetchState> = places
                    .iter()
                    .filter(|pl| p.applies_to(pl))
                    .map(|pl| db::fetch_state(c, pl.id, p.name()))
                    .collect::<anyhow::Result<_>>()?;
                let last = states.iter().filter_map(|s| s.last_success_at).max();
                let configured = p.configured(&config);
                let fresh = last.is_some_and(|t| now - t < 3 * 3_600_000);
                out.push(json!({
                    "provider": p,
                    "configured": configured,
                    "ok": !configured || states.is_empty() || fresh,
                    "last_success_at": last,
                    "error": states.iter().find_map(|s| s.error.clone()),
                }));
            }
            Ok(out)
        })
        .await?;
    let degraded = sources.iter().any(|s| s["ok"] == false);
    Ok(Json(json!({
        "status": if degraded { "degraded" } else { "ok" },
        "version": env!("CARGO_PKG_VERSION"),
        "sources": sources,
    })))
}

async fn me(principal: Principal) -> Json<Value> {
    Json(match principal {
        Principal::Session(owner) => json!({
            "kind": "session",
            "name": owner.name,
            "email": owner.email,
        }),
        Principal::DevAuto => json!({"kind": "dev"}),
        Principal::Device(d) => json!({"kind": "device", "name": d.name, "device_id": d.id}),
    })
}

/// Placeholder start page until the web app (M7): shows who is logged in.
async fn index(State(app): State<App>, headers: HeaderMap) -> AppResult<Response> {
    let Some(principal) = browser_principal(&app, &headers, None).await? else {
        return Ok(Redirect::to("/auth/login?return_to=/").into_response());
    };
    let who = match &principal {
        Principal::Session(owner) => owner
            .name
            .clone()
            .or_else(|| owner.email.clone())
            .unwrap_or_else(|| "angemeldet".into()),
        Principal::DevAuto => "Entwicklungsmodus".into(),
        Principal::Device(d) => d.name.clone(),
    };
    let who = who
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;");
    Ok(Html(format!(
        "<!doctype html><html lang=\"de\"><head><meta charset=\"utf-8\">\
         <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\
         <title>Witterung</title></head>\
         <body style=\"font-family: system-ui, sans-serif; max-width: 32rem; margin: 4rem auto; padding: 0 1rem\">\
         <h1>Witterung</h1><p>Server läuft. Angemeldet: {who}.</p></body></html>"
    ))
    .into_response())
}
