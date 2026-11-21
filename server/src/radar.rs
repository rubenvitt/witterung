//! Radar and warning map images from the DWD GeoServer (WMS).
//!
//! The DWD renders every GetMap request anew and needs 5–30 s for each one,
//! however small. A map built from 256-px tiles therefore stayed empty for
//! half a minute, and every frame of the time slider started over. So the
//! server fetches one image per frame for all of Germany, keeps it in memory
//! and keeps all frames of the current plan fetched in the background, so the
//! radar opens without waiting. Clients lay the image over their map at
//! `bbox` (EPSG:3857).

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::header;
use axum::response::{IntoResponse, Response};
use axum::Json;
use jiff::{SignedDuration, Timestamp};
use serde_json::{json, Value};
use tokio::sync::OnceCell;

use crate::app::App;
use crate::error::{AppError, AppResult};

pub const RADAR_LAYER: &str = "Radar_rv_product_1x1km_ger";
/// Warnings per municipality, merged into areas of equal level.
pub const WARNINGS_LAYER: &str = "Warnungen_Gemeinden_vereinigt";
const STEP: i64 = 300;
/// Frames before and after the last analysis (2 h each way).
const SPAN: i64 = 24;

/// Germany with the edge of the radar composite: 2–18° E, 46–56° N in Web
/// Mercator metres (minX, minY, maxX, maxY).
pub const BBOX: [f64; 4] = [222_638.98, 5_780_349.22, 2_003_750.83, 7_558_415.66];
/// ≈ 1 km per pixel at 52° N, the resolution of the radar product.
pub const WIDTH: u32 = 1024;
pub const HEIGHT: u32 = 1022;

/// One image per frame; a forecast frame is keyed with its run, so a new run
/// replaces it.
type Key = (i64, i64);

#[derive(Default)]
pub struct RadarCache {
    frames: Mutex<HashMap<Key, Arc<OnceCell<Bytes>>>>,
    warnings: tokio::sync::Mutex<Option<(Timestamp, Bytes)>>,
    end: Mutex<Option<(Timestamp, i64)>>,
}

/// The current frames: 5-minute steps, `SPAN` back from the last analysis
/// (`now_index`) and the 2 h forecast after it.
#[derive(Debug, Clone, PartialEq)]
pub struct Plan {
    pub end: i64,
    pub frames: Vec<i64>,
    pub now_index: usize,
}

impl Plan {
    pub fn new(end: i64) -> Self {
        let frames = (-2 * SPAN..=0).map(|k| end + k * STEP).collect();
        Plan {
            end,
            frames,
            now_index: SPAN as usize,
        }
    }

    /// Without capabilities: analyses appear about 5–10 minutes late.
    pub fn fallback(now: Timestamp) -> Self {
        Self::new(now.as_second().div_euclid(STEP) * STEP - 2 * STEP + SPAN * STEP)
    }

    pub fn analysis(&self) -> i64 {
        self.frames[self.now_index]
    }

    pub fn key(&self, t: i64) -> Key {
        (t, if t > self.analysis() { self.end } else { 0 })
    }

    /// Frames in the order the prefetch fetches them: from the last analysis
    /// outwards, so what the slider shows first is there first.
    pub fn by_distance(&self) -> Vec<i64> {
        let mut out = self.frames.clone();
        let now = self.analysis();
        out.sort_by_key(|t| ((t - now).abs(), *t < now));
        out
    }
}

/// `<Dimension name="time" …>start/END/PT5M` → END.
pub fn parse_time_end(capabilities: &str) -> Option<Timestamp> {
    let dim = capabilities.split("<Dimension name=\"time\"").nth(1)?;
    let text = dim.split('>').nth(1)?.split('<').next()?;
    text.split(',')
        .next_back()?
        .split('/')
        .nth(1)?
        .trim()
        .parse()
        .ok()
}

fn cache(app: &App) -> &RadarCache {
    app.radar()
}

/// End of the layer's time dimension (= last analysis + 2 h forecast), from
/// the WMS capabilities, cached for 2 minutes.
async fn plan(app: &App) -> Plan {
    let now = Timestamp::now();
    if let Some((at, end)) = *cache(app).end.lock().unwrap_or_else(|e| e.into_inner()) {
        if now.duration_since(at) < SignedDuration::from_mins(2) {
            return Plan::new(end);
        }
    }
    let base = &app.config().endpoints.dwd_geoserver;
    let Ok(url) = base.join(&format!(
        "{RADAR_LAYER}/ows?service=WMS&version=1.3.0&request=GetCapabilities"
    )) else {
        return Plan::fallback(now);
    };
    let end = async {
        let body = app.http().get(url).send().await.ok()?.text().await.ok()?;
        parse_time_end(&body)
    }
    .await;
    match end {
        Some(end) => {
            let end = end.as_second();
            *cache(app).end.lock().unwrap_or_else(|e| e.into_inner()) = Some((now, end));
            Plan::new(end)
        }
        None => Plan::fallback(now),
    }
}

fn get_map_url(app: &App, layer: &str, time: Option<i64>) -> Result<url::Url, AppError> {
    let mut url = app
        .config()
        .endpoints
        .dwd_geoserver
        .join("wms")
        .map_err(|e| AppError::Internal(e.into()))?;
    let bbox = BBOX.map(|v| format!("{v:.2}")).join(",");
    url.query_pairs_mut()
        .append_pair("SERVICE", "WMS")
        .append_pair("VERSION", "1.3.0")
        .append_pair("REQUEST", "GetMap")
        .append_pair("LAYERS", &format!("dwd:{layer}"))
        .append_pair("STYLES", "")
        .append_pair("CRS", "EPSG:3857")
        .append_pair("BBOX", &bbox)
        .append_pair("WIDTH", &WIDTH.to_string())
        .append_pair("HEIGHT", &HEIGHT.to_string())
        .append_pair("FORMAT", "image/png")
        .append_pair("TRANSPARENT", "true");
    if let Some(t) = time {
        let t = Timestamp::from_second(t).map_err(|e| AppError::Internal(e.into()))?;
        url.query_pairs_mut().append_pair("TIME", &t.to_string());
    }
    Ok(url)
}

/// One GetMap image. The DWD answers errors with status 200 and XML, so the
/// content type decides.
async fn fetch(app: &App, layer: &str, time: Option<i64>) -> Result<Bytes, AppError> {
    let url = get_map_url(app, layer, time)?;
    let upstream = |e: reqwest::Error| AppError::Upstream(format!("DWD: {}", e.without_url()));
    let response = app
        .http()
        .get(url)
        // Longer than the client default: the DWD regularly needs 15–30 s.
        .timeout(Duration::from_secs(60))
        .send()
        .await
        .map_err(upstream)?;
    let status = response.status();
    let is_png = response
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v.starts_with("image/png"));
    let body = response.bytes().await.map_err(upstream)?;
    if !status.is_success() || !is_png {
        let text = String::from_utf8_lossy(&body[..body.len().min(200)]).into_owned();
        return Err(AppError::Upstream(format!(
            "DWD liefert kein Radarbild ({status}): {text}"
        )));
    }
    Ok(body)
}

/// The image of frame `t`, from the cache or fetched once (parallel requests
/// for the same frame wait for the same download).
async fn frame(app: &App, plan: &Plan, t: i64) -> Result<Bytes, AppError> {
    let cell = cache(app)
        .frames
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .entry(plan.key(t))
        .or_default()
        .clone();
    cell.get_or_try_init(|| fetch(app, RADAR_LAYER, Some(t)))
        .await
        .cloned()
}

/// Drops images that are no longer frames (old analyses, replaced runs).
fn prune(app: &App, plan: &Plan) {
    let keep: std::collections::HashSet<Key> = plan.frames.iter().map(|&t| plan.key(t)).collect();
    cache(app)
        .frames
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .retain(|k, _| keep.contains(k));
}

/// Parallel downloads; the DWD does not slow them down (measured with 6).
const PARALLEL: usize = 6;

/// Keeps the frames of the current plan and the warnings in memory, all the
/// time: the DWD GeoServer is open data without a key or quota, and a radar
/// that waits 30 s for its first image is the problem this module solves.
/// Per new analysis (every 5 min) that is one measured frame plus the 24
/// frames of the new forecast run, ≈ 300 requests an hour.
pub fn spawn_prefetch(app: App) {
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_secs(60));
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            tick.tick().await;
            let warnings = async {
                if let Err(e) = warnings(&app).await {
                    tracing::warn!(error = %e, "warnings prefetch");
                }
            };
            tokio::join!(prefetch(&app), warnings);
        }
    });
}

/// Fetches all missing frames of the current plan.
pub async fn prefetch(app: &App) {
    let plan = plan(app).await;
    prune(app, &plan);
    let missing: Vec<i64> = {
        let frames = cache(app).frames.lock().unwrap_or_else(|e| e.into_inner());
        plan.by_distance()
            .into_iter()
            .filter(|&t| frames.get(&plan.key(t)).is_none_or(|c| !c.initialized()))
            .collect()
    };
    let plan = Arc::new(plan);
    let mut tasks = tokio::task::JoinSet::new();
    for t in missing {
        while tasks.len() >= PARALLEL {
            tasks.join_next().await;
        }
        let (app, plan) = (app.clone(), plan.clone());
        tasks.spawn(async move {
            if let Err(e) = frame(&app, &plan, t).await {
                tracing::warn!(error = %e, t, "radar prefetch");
            }
        });
    }
    while tasks.join_next().await.is_some() {}
}

/// `GET /api/v1/radar`
pub async fn radar(State(app): State<App>) -> Json<Value> {
    let plan = plan(&app).await;
    // Start the downloads now, not with the next tick.
    {
        let app = app.clone();
        tokio::spawn(async move { prefetch(&app).await });
    }
    let frames: Vec<String> = plan
        .frames
        .iter()
        .filter_map(|&t| Timestamp::from_second(t).ok())
        .map(|t| t.to_string())
        .collect();
    let base = app
        .config()
        .endpoints
        .dwd_geoserver
        .as_str()
        .trim_end_matches('/');
    Json(json!({
        "wms": format!("{base}/wms"),
        "layer": format!("dwd:{RADAR_LAYER}"),
        "frames": frames,
        "now_index": plan.now_index,
        "image": {
            "bbox": BBOX,
            "crs": "EPSG:3857",
            "width": WIDTH,
            "height": HEIGHT,
            "frame": "/api/v1/radar/frames/{unix}",
            "warnings": "/api/v1/radar/warnings",
        },
        "attribution": "Radar und Warnungen: Deutscher Wetterdienst",
    }))
}

fn png(body: Bytes, max_age: u32) -> Response {
    (
        [
            (header::CONTENT_TYPE, "image/png".to_owned()),
            (header::CACHE_CONTROL, format!("private, max-age={max_age}")),
        ],
        body,
    )
        .into_response()
}

/// `GET /api/v1/radar/frames/{unix}`: the image of one frame (PNG, `bbox`).
pub async fn frame_image(State(app): State<App>, Path(t): Path<i64>) -> AppResult<Response> {
    let plan = plan(&app).await;
    if !plan.frames.contains(&t) {
        return Err(AppError::NotFound);
    }
    let body = frame(&app, &plan, t).await?;
    // Analyses stay; a forecast frame changes with the next run.
    let max_age = if t > plan.analysis() { 240 } else { 3 * 3600 };
    Ok(png(body, max_age))
}

/// `GET /api/v1/radar/warnings`: current DWD warnings as areas (PNG, `bbox`),
/// cached for 5 minutes.
pub async fn warnings_image(State(app): State<App>) -> AppResult<Response> {
    let (body, max_age) = warnings(&app).await?;
    Ok(png(body, max_age))
}

/// The warnings image and its max-age, fetched at most every 5 minutes.
async fn warnings(app: &App) -> AppResult<(Bytes, u32)> {
    let mut cached = cache(app).warnings.lock().await;
    let now = Timestamp::now();
    if let Some((at, body)) = cached.as_ref() {
        if now.duration_since(*at) < SignedDuration::from_mins(5) {
            return Ok((body.clone(), 300));
        }
    }
    match fetch(app, WARNINGS_LAYER, None).await {
        Ok(body) => {
            *cached = Some((now, body.clone()));
            Ok((body, 300))
        }
        // An older picture is better than none.
        Err(e) => match cached.as_ref() {
            Some((_, body)) => {
                tracing::warn!(error = %e, "warnings image");
                Ok((body.clone(), 60))
            }
            None => Err(e),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn time_end() {
        let caps = r#"<Layer><Dimension name="time" default="current" units="ISO8601">2026-11-06T00:00:00.000Z/2026-11-09T14:55:00.000Z/PT5M</Dimension></Layer>"#;
        assert_eq!(
            parse_time_end(caps).unwrap().to_string(),
            "2026-11-09T14:55:00Z"
        );
        assert!(parse_time_end("<x/>").is_none());
    }

    #[test]
    fn plan_and_keys() {
        let end: i64 = "2026-11-09T14:55:00Z"
            .parse::<Timestamp>()
            .unwrap()
            .as_second();
        let p = Plan::new(end);
        assert_eq!(p.frames.len(), 49);
        assert_eq!(p.analysis(), end - 7200);
        assert_eq!(p.frames[0], end - 14_400);
        // Measured frames stay across runs, forecast frames belong to theirs.
        assert_eq!(p.key(p.analysis()), (p.analysis(), 0));
        assert_eq!(p.key(end), (end, end));
        let order = p.by_distance();
        assert_eq!(order[0], p.analysis());
        assert_eq!(order[1], p.analysis() + STEP);
        assert_eq!(order[2], p.analysis() - STEP);
        assert_eq!(order.len(), 49);
    }

    #[test]
    fn bbox_is_square_pixels() {
        let (w, h) = (BBOX[2] - BBOX[0], BBOX[3] - BBOX[1]);
        let ratio = (w / f64::from(WIDTH)) / (h / f64::from(HEIGHT));
        assert!((ratio - 1.0).abs() < 0.002, "{ratio}");
    }
}
