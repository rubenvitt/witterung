//! Weather API (behind login): places and the raw per-source data.

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::Json;
use jiff::Timestamp;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::app::{now_ms, App};
use crate::db::{self, Place};
use crate::error::{AppError, AppResult};
use crate::poller::{Provider, STALE_AFTER};
use crate::quota;

pub async fn list_places(State(app): State<App>) -> AppResult<Json<Vec<Place>>> {
    Ok(Json(app.blocking(db::list_places).await?))
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
    let name = new.name.trim().to_owned();
    if name.is_empty() || name.chars().count() > 80 {
        return Err(AppError::BadRequest("Name: 1 bis 80 Zeichen".into()));
    }
    if !(-90.0..=90.0).contains(&new.lat) || !(-180.0..=180.0).contains(&new.lon) {
        return Err(AppError::BadRequest(
            "Koordinaten außerhalb des gültigen Bereichs".into(),
        ));
    }
    let place = app
        .blocking(move |c| db::insert_place(c, &name, new.lat, new.lon, now_ms()))
        .await?;
    Ok((StatusCode::CREATED, Json(place)))
}

/// Everything stored for a place, unmerged: per-source series, poll state
/// and quota per provider, attribution. The aggregated forecast comes in M2.
pub async fn raw(State(app): State<App>, Path(id): Path<i64>) -> AppResult<Json<Value>> {
    let now = Timestamp::now();
    let body = app
        .blocking(move |c| {
            let Some(place) = db::find_place(c, id)? else {
                return Ok(None);
            };
            let mut providers = Vec::new();
            for p in Provider::ALL {
                let state = db::fetch_state(c, id, p.name())?;
                let usage = quota::usage(c, p.name(), p.budget(), now)?;
                providers.push(json!({
                    "provider": p,
                    "state": state,
                    "quota": usage,
                }));
            }
            let mut sources = Vec::new();
            for (source, fetched_at, data) in db::snapshots(c, id)? {
                let data: Value = serde_json::from_str(&data)?;
                let age_ms = now.as_millisecond() - fetched_at;
                sources.push(json!({
                    "source": source,
                    "fetched_at": fetched_at,
                    "stale": age_ms > STALE_AFTER.as_millis() as i64,
                    "hourly": data["hourly"],
                    "daily": data["daily"],
                }));
            }
            let attribution: Vec<_> = Provider::ALL.iter().map(|p| p.attribution()).collect();
            Ok(Some(json!({
                "place": place,
                "providers": providers,
                "sources": sources,
                "attribution": attribution,
            })))
        })
        .await?;
    body.map(Json).ok_or(AppError::NotFound)
}
