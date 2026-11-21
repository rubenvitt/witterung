//! Weather API (behind login), see docs/api.md.

use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::Json;
use jiff::{SignedDuration, Timestamp};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::app::{now_ms, App};
use crate::auth::{device, Principal};
use crate::db::{self, Device, Place, PlaceUpdate};
use crate::error::{AppError, AppResult};
use crate::forecast::{self, Forecast, Snapshot};
use crate::poller::{self, Provider};
use crate::quota;

/// Grid for the current location (≈ 2 km), so small moves hit the cache.
const GRID: f64 = 0.02;

pub fn check_coords(lat: f64, lon: f64) -> AppResult<()> {
    if (-90.0..=90.0).contains(&lat) && (-180.0..=180.0).contains(&lon) {
        Ok(())
    } else {
        Err(AppError::BadRequest(
            "Koordinaten außerhalb des gültigen Bereichs".into(),
        ))
    }
}

pub fn check_name(name: &str) -> AppResult<String> {
    let name = name.trim();
    if name.is_empty() || name.chars().count() > 80 {
        return Err(AppError::BadRequest("Name: 1 bis 80 Zeichen".into()));
    }
    Ok(name.to_owned())
}

pub async fn list_places(State(app): State<App>) -> AppResult<Json<Vec<Place>>> {
    let places = app.blocking(db::list_places).await?;
    Ok(Json(
        places.into_iter().filter(|p| p.kind == "saved").collect(),
    ))
}

#[derive(Deserialize)]
pub struct NewPlace {
    name: String,
    lat: f64,
    lon: f64,
}

pub async fn create_place(
    State(app): State<App>,
    Json(new): Json<NewPlace>,
) -> AppResult<(StatusCode, Json<Place>)> {
    let name = check_name(&new.name)?;
    check_coords(new.lat, new.lon)?;
    let place = app
        .blocking(move |c| db::insert_place(c, &name, new.lat, new.lon, now_ms()))
        .await?;
    Ok((StatusCode::CREATED, Json(place)))
}

pub async fn update_place(
    State(app): State<App>,
    Path(id): Path<i64>,
    Json(mut update): Json<PlaceUpdate>,
) -> AppResult<Json<Place>> {
    if let Some(name) = &update.name {
        update.name = Some(check_name(name)?);
    }
    let place = app
        .blocking(move |c| {
            if !db::update_place(c, id, &update)? {
                return Ok(None);
            }
            db::find_place(c, id)
        })
        .await?;
    place.map(Json).ok_or(AppError::NotFound)
}

pub async fn delete_place(State(app): State<App>, Path(id): Path<i64>) -> AppResult<StatusCode> {
    if app.blocking(move |c| db::delete_place(c, id)).await? {
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(AppError::NotFound)
    }
}

/// The aggregated forecast of a stored place.
pub async fn forecast_for(app: &App, place: Place) -> AppResult<Forecast> {
    let id = place.id;
    let (snapshots, states) = app
        .blocking(move |c| {
            let snaps = db::snapshots(c, id)?
                .into_iter()
                .map(|(key, fetched_at, json)| Snapshot {
                    key,
                    fetched_at,
                    json,
                })
                .collect::<Vec<_>>();
            let states = Provider::ALL
                .iter()
                .map(|&p| Ok((p, db::fetch_state(c, id, p.name())?)))
                .collect::<anyhow::Result<Vec<_>>>()?;
            Ok((snaps, states))
        })
        .await?;
    let configured: Vec<Provider> = Provider::ALL
        .into_iter()
        .filter(|p| p.configured(app.config()) && p.applies_to(&place))
        .collect();
    Ok(forecast::build(
        place,
        snapshots,
        &states,
        &configured,
        Timestamp::now(),
    ))
}

pub async fn place_forecast(
    State(app): State<App>,
    Path(id): Path<i64>,
) -> AppResult<Json<Forecast>> {
    let (place, empty) = app
        .blocking(move |c| {
            let Some(place) = db::find_place(c, id)? else {
                return Ok(None);
            };
            let empty = db::snapshots(c, place.id)?.is_empty();
            Ok(Some((place, empty)))
        })
        .await?
        .ok_or(AppError::NotFound)?;
    // A new place has nothing until the poller comes by; fetch the free
    // sources now instead of answering with an empty forecast.
    if empty {
        poll_free_sources(&app, &place).await;
    }
    Ok(Json(forecast_for(&app, place).await?))
}

/// The sources without a quota, fetched right away for a place without data.
async fn poll_free_sources(app: &App, place: &Place) {
    poller::poll_place(
        app,
        place,
        &[
            Provider::OpenMeteo,
            Provider::BrightSky,
            Provider::DwdObservation,
            Provider::DwdAlerts,
            Provider::DwdRadar,
        ],
        Timestamp::now(),
    )
    .await;
}

#[derive(Deserialize)]
pub struct Coords {
    lat: f64,
    lon: f64,
}

/// Forecast for the device location; first use fetches the free sources
/// right away.
pub async fn location_forecast(
    State(app): State<App>,
    Query(q): Query<Coords>,
) -> AppResult<Json<Forecast>> {
    Ok(Json(forecast_at(&app, q.lat, q.lon).await?))
}

/// Forecast for arbitrary coordinates: snapped to a ≈ 2 km grid and kept as
/// a `current` place (polled while requested within 24 h); the first request
/// fetches the free sources right away.
pub async fn forecast_at(app: &App, lat: f64, lon: f64) -> AppResult<Forecast> {
    check_coords(lat, lon)?;
    let snap = |v: f64| ((v / GRID).round() * GRID * 1e4).round() / 1e4;
    let (lat, lon) = (snap(lat), snap(lon));
    let (place, empty) = app
        .blocking(move |c| {
            let place = db::current_place(c, lat, lon, now_ms())?;
            let empty = db::snapshots(c, place.id)?.is_empty();
            Ok((place, empty))
        })
        .await?;
    if empty {
        poll_free_sources(app, &place).await;
    }
    forecast_for(app, place).await
}

/// Everything stored for a place, unmerged (debugging, source comparison).
pub async fn raw(State(app): State<App>, Path(id): Path<i64>) -> AppResult<Json<Value>> {
    let now = Timestamp::now();
    let config = app.config().clone();
    let body = app
        .blocking(move |c| {
            let Some(place) = db::find_place(c, id)? else {
                return Ok(None);
            };
            let mut providers = Vec::new();
            for p in Provider::ALL {
                providers.push(json!({
                    "provider": p,
                    "configured": p.configured(&config),
                    "state": db::fetch_state(c, id, p.name())?,
                    "quota": quota::usage(c, p.quota_key(), p.budget(), now)?,
                }));
            }
            let mut sources = Vec::new();
            for (key, fetched_at, data) in db::snapshots(c, id)? {
                let stale_after = forecast::provider_of(&key)
                    .map_or(SignedDuration::from_hours(3), |p| p.stale_after());
                let data: Value = serde_json::from_str(&data)?;
                sources.push(json!({
                    "source": key,
                    "fetched_at": fetched_at,
                    "stale": now.as_millisecond() - fetched_at > stale_after.as_millis() as i64,
                    "data": data,
                }));
            }
            Ok(Some(
                json!({"place": place, "providers": providers, "sources": sources}),
            ))
        })
        .await?;
    body.map(Json).ok_or(AppError::NotFound)
}

/// Per provider: configured, last state across places, quota.
pub async fn status(State(app): State<App>) -> AppResult<Json<Value>> {
    Ok(Json(json!({"providers": provider_status(&app).await?})))
}

/// The provider list of [`status`].
pub async fn provider_status(app: &App) -> AppResult<Vec<Value>> {
    let now = Timestamp::now();
    let config = app.config().clone();
    app.blocking(move |c| {
        let places = db::list_places(c)?;
        let mut out = Vec::new();
        for p in Provider::ALL {
            let states: Vec<db::FetchState> = places
                .iter()
                .map(|pl| db::fetch_state(c, pl.id, p.name()))
                .collect::<anyhow::Result<_>>()?;
            let last_success = states.iter().filter_map(|s| s.last_success_at).max();
            let error = states.iter().find_map(|s| s.error.clone());
            out.push(json!({
                "provider": p,
                "configured": p.configured(&config),
                "ok": p.configured(&config) && error.is_none(),
                "last_success_at": last_success,
                "error": error,
                "interval_s": p.interval().as_secs(),
                "quota": quota::usage(c, p.quota_key(), p.budget(), now)?,
                "quota_account": p.quota_key(),
            }));
        }
        Ok(out)
    })
    .await
}

pub async fn list_devices(State(app): State<App>) -> AppResult<Json<Vec<Device>>> {
    Ok(Json(app.blocking(db::list_devices).await?))
}

#[derive(Deserialize)]
pub struct NewDevice {
    name: String,
}

/// Token for a client without a browser (e.g. the Mac menu bar), shown once.
/// Only a browser session may do this: a device token must not mint more.
pub async fn create_device(
    State(app): State<App>,
    principal: Principal,
    Json(new): Json<NewDevice>,
) -> AppResult<(StatusCode, Json<Value>)> {
    let subject = match principal {
        Principal::Session(owner) => owner.subject,
        Principal::DevAuto => None,
        Principal::Device(_) => {
            return Err(AppError::Forbidden(
                "Geräte-Token können keine weiteren Token erzeugen".into(),
            ))
        }
    };
    let name = new.name.trim().to_owned();
    if !device::valid_name(&name) {
        return Err(AppError::BadRequest("Name: 1 bis 60 Zeichen".into()));
    }
    let key = app.config().session_secret.clone();
    let (token, id) = app
        .blocking(move |c| device::issue_token(c, &key, &name, subject.as_deref(), now_ms()))
        .await?;
    tracing::info!(device = id, "device token created in the web app");
    Ok((
        StatusCode::CREATED,
        Json(json!({"token": token, "device_id": id})),
    ))
}

/// OAuth clients with a live grant on `/mcp` (claude.ai connectors and
/// the like).
pub async fn list_connections(State(app): State<App>) -> AppResult<Json<Vec<db::OAuthClient>>> {
    let now = now_ms();
    Ok(Json(
        app.blocking(move |c| db::connected_oauth_clients(c, now))
            .await?,
    ))
}

/// Disconnects an OAuth client: removes it with all its tokens.
pub async fn delete_connection(
    State(app): State<App>,
    Path(id): Path<String>,
) -> AppResult<StatusCode> {
    if app
        .blocking(move |c| db::delete_oauth_client(c, &id))
        .await?
    {
        tracing::info!("OAuth client disconnected in the web app");
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(AppError::NotFound)
    }
}

pub async fn delete_device(State(app): State<App>, Path(id): Path<i64>) -> AppResult<StatusCode> {
    if app.blocking(move |c| db::delete_device(c, id)).await? {
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(AppError::NotFound)
    }
}
