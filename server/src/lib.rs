//! Witterung server: login, health, the weather API and the MCP endpoint.

pub mod api;
pub mod app;
pub mod auth;
pub mod backup;
pub mod config;
pub mod db;
pub mod error;
pub mod forecast;
pub mod healthcheck;
pub mod mcp;
pub mod oauth;
pub mod poller;
pub mod push;
pub mod quota;
pub mod sources;
pub mod web;

use axum::extract::State;
use axum::routing::get;
use axum::Router;
use axum::{middleware, Json};
use serde_json::{json, Value};

pub use app::App;
pub use config::Config;

use auth::middleware::require_auth;
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
        .route(
            "/api/v1/devices",
            get(api::list_devices).post(api::create_device),
        )
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
        .route("/api/v1/connections", get(api::list_connections))
        .route(
            "/api/v1/connections/{id}",
            axum::routing::delete(api::delete_connection),
        )
        .route_layer(middleware::from_fn_with_state(app.clone(), require_auth));
    let router = Router::new()
        .route("/", get(web::index))
        .route("/assets/{name}", get(web::asset))
        .route("/health", get(health))
        .merge(auth::routes::routes())
        .merge(auth::device::routes())
        .merge(mcp::routes())
        .merge(api)
        .with_state(app.clone())
        .merge(oauth::routes::routes(oauth::routes::OAuthState::new(
            app.clone(),
        )));
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
    // The peer address feeds the rate limit of the OAuth client registration.
    axum::serve(
        listener,
        router.into_make_service_with_connect_info::<std::net::SocketAddr>(),
    )
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
