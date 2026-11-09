//! Weather API (behind login), see docs/api.md.

use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::Json;
use jiff::{SignedDuration, Timestamp};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::app::{now_ms, App};
use crate::db::{self, Device, Place, PlaceUpdate};
use crate::error::{AppError, AppResult};
use crate::forecast::{self, Forecast, Snapshot};
use crate::poller::{self, Provider};
use crate::quota;

/// Grid for the current location (≈ 2 km), so small moves hit the cache.
const GRID: f64 = 0.02;

fn check_coords(lat: f64, lon: f64) -> AppResult<()> {
    if (-90.0..=90.0).contains(&lat) && (-180.0..=180.0).contains(&lon) {
        Ok(())
    } else {
        Err(AppError::BadRequest(
            "Koordinaten außerhalb des gültigen Bereichs".into(),
        ))
    }
}

fn check_name(name: &str) -> AppResult<String> {
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

async fn forecast_for(app: &App, place: Place) -> AppResult<Forecast> {
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
    let place = app
        .blocking(move |c| db::find_place(c, id))
        .await?
        .ok_or(AppError::NotFound)?;
    Ok(Json(forecast_for(&app, place).await?))
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
    check_coords(q.lat, q.lon)?;
    let snap = |v: f64| ((v / GRID).round() * GRID * 1e4).round() / 1e4;
    let (lat, lon) = (snap(q.lat), snap(q.lon));
    let (place, empty) = app
        .blocking(move |c| {
            let place = db::current_place(c, lat, lon, now_ms())?;
            let empty = db::snapshots(c, place.id)?.is_empty();
            Ok((place, empty))
        })
        .await?;
    if empty {
        poller::poll_place(
            &app,
            &place,
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
    Ok(Json(forecast_for(&app, place).await?))
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
    let now = Timestamp::now();
    let config = app.config().clone();
    let providers = app
        .blocking(move |c| {
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
        .await?;
    Ok(Json(json!({"providers": providers})))
}

/// Radar frames for the DWD WMS (5 min, −2 h … +2 h around the last
/// analysis).
pub async fn radar() -> Json<Value> {
    let now = Timestamp::now().as_second();
    let step = 300;
    let last_analysis = now.div_euclid(step) * step - step;
    let frames: Vec<String> = (-24..=24)
        .filter_map(|k| Timestamp::from_second(last_analysis + k * step).ok())
        .map(|t| t.to_string())
        .collect();
    Json(json!({
        "wms": "https://maps.dwd.de/geoserver/dwd/wms",
        "layer": "dwd:Radar_rv_product_1x1km_ger",
        "frames": frames,
        "now_index": 24,
        "attribution": "Radar: Deutscher Wetterdienst",
    }))
}

pub async fn list_devices(State(app): State<App>) -> AppResult<Json<Vec<Device>>> {
    Ok(Json(app.blocking(db::list_devices).await?))
}

pub async fn delete_device(State(app): State<App>, Path(id): Path<i64>) -> AppResult<StatusCode> {
    if app.blocking(move |c| db::delete_device(c, id)).await? {
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(AppError::NotFound)
    }
}
