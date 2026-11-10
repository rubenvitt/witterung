//! MCP tools: definitions (name, description, input schema, annotations)
//! and handlers. Forecasts are built exactly like `/api/v1/…/forecast`, but
//! shaped for a language model: local times, no null fields, per-source
//! values only on request, and a nowcast sentence.

use jiff::{SignedDuration, Timestamp};
use serde_json::{json, Map, Value};

use crate::api;
use crate::app::{now_ms, App};
use crate::db::{self, Place, PlaceUpdate};
use crate::error::{AppError, AppResult};
use crate::forecast::{Forecast, Range};
use crate::poller::{self, Provider};
use crate::sources::{berlin, berlin_time};

/// One tool.
struct ToolDef {
    name: &'static str,
    title: &'static str,
    description: &'static str,
    input_schema: Value,
    read_only: bool,
    destructive: bool,
    idempotent: bool,
}

impl ToolDef {
    fn to_json(&self) -> Value {
        let mut annotations = json!({
            "title": self.title,
            "readOnlyHint": self.read_only,
            "openWorldHint": false,
        });
        if !self.read_only {
            annotations["destructiveHint"] = json!(self.destructive);
            annotations["idempotentHint"] = json!(self.idempotent);
        }
        json!({
            "name": self.name,
            "title": self.title,
            "description": self.description,
            "inputSchema": self.input_schema,
            "annotations": annotations,
        })
    }
}

const PLACE_DESCRIPTION: &str =
    "Gespeicherter Ort: ID (Zahl) oder Name (Groß-/Kleinschreibung egal, eindeutiger Teil genügt)";

fn place_schema() -> Value {
    json!({"type": ["integer", "string"], "description": PLACE_DESCRIPTION})
}

fn definitions() -> Vec<ToolDef> {
    vec![
        ToolDef {
            name: "list_places",
            title: "Orte auflisten",
            description: "Listet die gespeicherten Orte (ID, Name, Koordinaten, ob Push-Hinweise \
                          aktiv sind) in der Reihenfolge der App.",
            input_schema: json!({"type": "object", "properties": {}, "additionalProperties": false}),
            read_only: true,
            destructive: false,
            idempotent: true,
        },
        ToolDef {
            name: "get_forecast",
            title: "Vorhersage abrufen",
            description: "Konsens-Vorhersage für einen gespeicherten Ort (place) oder beliebige \
                          Koordinaten (lat und lon): aktuelle Messung, Radar-Nowcast der nächsten \
                          2 Stunden, stündliche Werte (bis 48 h), Tageswerte (bis 10 Tage), \
                          DWD-Warnungen und Zustand der Quellen. Jede Zeile hat den Median der \
                          Quellen, die Spannweite (spread) und n_sources. Entweder place oder \
                          lat/lon angeben.",
            input_schema: json!({
                "type": "object",
                "properties": {
                    "place": place_schema(),
                    "lat": {"type": "number", "minimum": -90, "maximum": 90,
                            "description": "Breitengrad (WGS84), zusammen mit lon"},
                    "lon": {"type": "number", "minimum": -180, "maximum": 180,
                            "description": "Längengrad (WGS84), zusammen mit lat"},
                    "hours": {"type": "integer", "minimum": 0, "maximum": 48, "default": 24,
                              "description": "Wie viele Stunden ab jetzt (0 = keine stündlichen Werte)"},
                    "days": {"type": "integer", "minimum": 0, "maximum": 10, "default": 7,
                             "description": "Wie viele Tage ab heute (0 = keine Tageswerte)"},
                    "by_source": {"type": "boolean", "default": false,
                                  "description": "Zusätzlich die Werte jeder einzelnen Quelle (zum Vergleich der Modelle; deutlich längere Antwort)"}
                },
                "additionalProperties": false
            }),
            read_only: true,
            destructive: false,
            idempotent: true,
        },
        ToolDef {
            name: "get_alerts",
            title: "Warnungen abrufen",
            description: "Aktuelle amtliche DWD-Warnungen (Unwetter, Glätte, Hitze …) für einen \
                          gespeicherten Ort oder, ohne place, für alle gespeicherten Orte.",
            input_schema: json!({
                "type": "object",
                "properties": {"place": place_schema()},
                "additionalProperties": false
            }),
            read_only: true,
            destructive: false,
            idempotent: true,
        },
        ToolDef {
            name: "get_source_status",
            title: "Quellenstatus",
            description: "Zustand der Wetterquellen: konfiguriert, letzter erfolgreicher Abruf, \
                          letzter Fehler, Abrufintervall und Kontingent.",
            input_schema: json!({"type": "object", "properties": {}, "additionalProperties": false}),
            read_only: true,
            destructive: false,
            idempotent: true,
        },
        ToolDef {
            name: "create_place",
            title: "Ort anlegen",
            description:
                "Speichert einen neuen Ort; er erscheint in App, Web und Widgets und wird \
                          ab sofort regelmäßig abgerufen. Koordinaten in WGS84.",
            input_schema: json!({
                "type": "object",
                "properties": {
                    "name": {"type": "string", "minLength": 1, "maxLength": 80},
                    "lat": {"type": "number", "minimum": -90, "maximum": 90},
                    "lon": {"type": "number", "minimum": -180, "maximum": 180}
                },
                "required": ["name", "lat", "lon"],
                "additionalProperties": false
            }),
            read_only: false,
            destructive: false,
            idempotent: false,
        },
        ToolDef {
            name: "update_place",
            title: "Ort ändern",
            description: "Benennt einen gespeicherten Ort um, schaltet seine Push-Hinweise \
                          (Regen, Warnungen über ntfy) oder verschiebt ihn in der Reihenfolge.",
            input_schema: json!({
                "type": "object",
                "properties": {
                    "place": place_schema(),
                    "name": {"type": "string", "minLength": 1, "maxLength": 80},
                    "notify": {"type": "boolean", "description": "Push-Hinweise für diesen Ort"},
                    "position": {"type": "integer", "minimum": 0,
                                 "description": "Neue Position unter den gespeicherten Orten (0 = erster)"}
                },
                "required": ["place"],
                "additionalProperties": false
            }),
            read_only: false,
            destructive: false,
            idempotent: true,
        },
        ToolDef {
            name: "delete_place",
            title: "Ort löschen",
            description:
                "Löscht einen gespeicherten Ort samt seinen gespeicherten Abrufen. Nur auf \
                          ausdrücklichen Wunsch des Nutzers.",
            input_schema: json!({
                "type": "object",
                "properties": {"place": place_schema()},
                "required": ["place"],
                "additionalProperties": false
            }),
            read_only: false,
            destructive: true,
            idempotent: true,
        },
    ]
}

/// The `tools/list` result.
pub fn list() -> Value {
    json!({"tools": definitions().iter().map(ToolDef::to_json).collect::<Vec<_>>()})
}

/// Runs a tool and returns the `tools/call` result (`None` for an unknown
/// tool). Errors become results with `isError: true`.
pub async fn call(app: &App, name: &str, args: Map<String, Value>) -> Option<Value> {
    let defs = definitions();
    let def = defs.iter().find(|t| t.name == name)?;
    let result = match check_args(def, &args) {
        Ok(()) => dispatch(app, name, &args).await,
        Err(e) => Err(e),
    };
    Some(tool_result(result))
}

fn tool_result(result: AppResult<Value>) -> Value {
    match result {
        Ok(value) => json!({
            "content": [{"type": "text", "text": value.to_string()}],
            "structuredContent": value,
            "isError": false,
        }),
        Err(e) => {
            if let AppError::Internal(inner) = &e {
                tracing::error!(error = ?inner, "MCP tool failed");
            }
            let message = e.to_string();
            json!({
                "content": [{"type": "text", "text": message}],
                "structuredContent": {"error": {"code": e.code(), "message": message}},
                "isError": true,
            })
        }
    }
}

/// Unknown and missing arguments are refused before anything runs.
fn check_args(def: &ToolDef, args: &Map<String, Value>) -> AppResult<()> {
    let props = def.input_schema["properties"].as_object();
    for key in args.keys() {
        if !props.is_some_and(|p| p.contains_key(key)) {
            return Err(AppError::BadRequest(format!("Unbekanntes Argument: {key}")));
        }
    }
    for required in def.input_schema["required"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
    {
        if args.get(required).is_none_or(Value::is_null) {
            return Err(AppError::BadRequest(format!("Argument fehlt: {required}")));
        }
    }
    Ok(())
}

async fn dispatch(app: &App, name: &str, args: &Map<String, Value>) -> AppResult<Value> {
    match name {
        "list_places" => list_places(app).await,
        "get_forecast" => get_forecast(app, args).await,
        "get_alerts" => get_alerts(app, args).await,
        "get_source_status" => Ok(json!({"providers": api::provider_status(app).await?})),
        "create_place" => create_place(app, args).await,
        "update_place" => update_place(app, args).await,
        "delete_place" => delete_place(app, args).await,
        _ => Err(AppError::BadRequest(format!(
            "Unbekanntes Werkzeug: {name}"
        ))),
    }
}

// ----- arguments ----------------------------------------------------------------

fn opt_f64(args: &Map<String, Value>, key: &str) -> AppResult<Option<f64>> {
    match args.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(v) => v
            .as_f64()
            .map(Some)
            .ok_or_else(|| AppError::BadRequest(format!("{key} muss eine Zahl sein"))),
    }
}

fn opt_bool(args: &Map<String, Value>, key: &str) -> AppResult<Option<bool>> {
    match args.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(b)) => Ok(Some(*b)),
        Some(_) => Err(AppError::BadRequest(format!(
            "{key} muss true oder false sein"
        ))),
    }
}

fn opt_str<'a>(args: &'a Map<String, Value>, key: &str) -> AppResult<Option<&'a str>> {
    match args.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => Ok(Some(s)),
        Some(_) => Err(AppError::BadRequest(format!("{key} muss ein Text sein"))),
    }
}

/// A whole number in `0..=max`, `default` when absent.
fn count(args: &Map<String, Value>, key: &str, default: u64, max: u64) -> AppResult<u64> {
    match args.get(key) {
        None | Some(Value::Null) => Ok(default),
        Some(v) => v.as_u64().filter(|n| *n <= max).ok_or_else(|| {
            AppError::BadRequest(format!("{key} muss eine ganze Zahl von 0 bis {max} sein"))
        }),
    }
}

/// Resolves `place` (ID or name) to a saved place.
async fn resolve_place(app: &App, value: &Value) -> AppResult<Place> {
    let saved: Vec<Place> = app
        .blocking(db::list_places)
        .await?
        .into_iter()
        .filter(|p| p.kind == "saved")
        .collect();
    let id = match value {
        Value::Number(n) => n.as_i64(),
        Value::String(s) => s.trim().parse::<i64>().ok(),
        _ => {
            return Err(AppError::BadRequest(
                "place muss eine ID oder ein Name sein".into(),
            ))
        }
    };
    if let Some(id) = id {
        return saved
            .into_iter()
            .find(|p| p.id == id)
            .ok_or_else(|| AppError::BadRequest(format!("Kein gespeicherter Ort mit ID {id}")));
    }
    let wanted = value.as_str().unwrap_or("").trim().to_lowercase();
    if wanted.is_empty() {
        return Err(AppError::BadRequest("place ist leer".into()));
    }
    if let Some(p) = saved.iter().find(|p| p.name.to_lowercase() == wanted) {
        return Ok(p.clone());
    }
    let matches: Vec<&Place> = saved
        .iter()
        .filter(|p| p.name.to_lowercase().contains(&wanted))
        .collect();
    match matches.as_slice() {
        [one] => Ok((*one).clone()),
        [] => Err(AppError::BadRequest(format!(
            "Kein gespeicherter Ort heißt „{}“. Vorhanden: {}. Für andere Orte lat/lon angeben.",
            value.as_str().unwrap_or_default().trim(),
            names(&saved)
        ))),
        many => Err(AppError::BadRequest(format!(
            "„{}“ ist mehrdeutig: {}",
            value.as_str().unwrap_or_default().trim(),
            many.iter()
                .map(|p| format!("{} (ID {})", p.name, p.id))
                .collect::<Vec<_>>()
                .join(", ")
        ))),
    }
}

fn names(places: &[Place]) -> String {
    if places.is_empty() {
        return "keine".into();
    }
    places
        .iter()
        .map(|p| p.name.as_str())
        .collect::<Vec<_>>()
        .join(", ")
}

// ----- output helpers -----------------------------------------------------------

/// Local time in Europe/Berlin with offset, to the minute.
fn local(t: Timestamp) -> String {
    t.to_zoned(berlin())
        .strftime("%Y-%m-%dT%H:%M%:z")
        .to_string()
}

/// Drops `null` fields of an object (shorter answers, nothing is lost).
fn compact(value: Value) -> Value {
    match value {
        Value::Object(map) => Value::Object(
            map.into_iter()
                .filter(|(_, v)| !v.is_null())
                .map(|(k, v)| (k, compact(v)))
                .collect(),
        ),
        Value::Array(items) => Value::Array(items.into_iter().map(compact).collect()),
        other => other,
    }
}

/// Replaces the timestamp fields `keys` of an object by local times.
fn localize(value: &mut Value, keys: &[&str]) {
    for key in keys {
        let parsed = value
            .get(*key)
            .and_then(Value::as_str)
            .and_then(|s| s.parse::<Timestamp>().ok());
        if let Some(t) = parsed {
            value[*key] = json!(local(t));
        }
    }
}

fn range(r: Range) -> Value {
    if r.min.is_finite() && r.max.is_finite() {
        json!([r.min, r.max])
    } else {
        Value::Null
    }
}

fn place_json(p: &Place) -> Value {
    json!({"id": p.id, "name": p.name, "lat": p.lat, "lon": p.lon, "notify": p.notify})
}

const WEEKDAYS: [&str; 7] = [
    "Montag",
    "Dienstag",
    "Mittwoch",
    "Donnerstag",
    "Freitag",
    "Samstag",
    "Sonntag",
];

/// Rain threshold of the nowcast sentence (mm/h).
const NOWCAST_WET_MM_H: f64 = 0.1;

/// One German sentence about the next two hours of radar nowcast, counted
/// from `now` (earlier points of an older radar run are skipped).
fn nowcast_summary(points: &[(Timestamp, f64)], now: Timestamp) -> String {
    let upcoming: Vec<(Timestamp, f64)> = points
        .iter()
        .copied()
        .filter(|(at, _)| *at > now - SignedDuration::from_mins(5))
        .collect();
    let peak = upcoming.iter().map(|(_, v)| *v).fold(0.0, f64::max);
    let Some(first) = upcoming.first() else {
        return "Keine aktuellen Radardaten.".into();
    };
    if peak < NOWCAST_WET_MM_H {
        return "Laut Radar kein Niederschlag in den nächsten 2 Stunden.".into();
    }
    let wet = |v: f64| v >= NOWCAST_WET_MM_H;
    if wet(first.1) {
        let dry = upcoming.iter().find(|(_, v)| !wet(*v));
        match dry {
            Some((at, _)) => format!(
                "Laut Radar Niederschlag jetzt, voraussichtlich bis etwa {} Uhr (bis zu {peak:.1} mm/h).",
                berlin_time(*at)
            ),
            None => format!(
                "Laut Radar Niederschlag jetzt und die nächsten 2 Stunden (bis zu {peak:.1} mm/h)."
            ),
        }
    } else {
        let start = upcoming
            .iter()
            .find(|(_, v)| wet(*v))
            .map_or(first.0, |(at, _)| *at);
        format!(
            "Laut Radar Niederschlag ab etwa {} Uhr (bis zu {peak:.1} mm/h).",
            berlin_time(start)
        )
    }
}

/// The forecast shaped for the model.
fn forecast_json(f: Forecast, saved: bool, hours: u64, days: u64, by_source: bool) -> Value {
    let now = f.generated_at;
    let location = if saved {
        place_json(&f.location)
    } else {
        json!({"lat": f.location.lat, "lon": f.location.lon,
               "note": "freie Koordinaten, auf ≈ 2 km gerundet"})
    };
    let observed = f.now.observed.map(|o| {
        let mut v = serde_json::to_value(o).unwrap_or_default();
        localize(&mut v, &["at"]);
        v
    });
    let current = f.now.forecast.map(|h| {
        let mut v = serde_json::to_value(h).unwrap_or_default();
        localize(&mut v, &["at"]);
        v
    });
    let nowcast = f.nowcast.map(|n| {
        let upcoming: Vec<_> = n
            .points
            .iter()
            .filter(|p| p.at > now - SignedDuration::from_mins(5))
            .collect();
        let points: Vec<(Timestamp, f64)> =
            n.points.iter().map(|p| (p.at, p.precip_mm_h)).collect();
        let mut v = json!({
            "summary": nowcast_summary(&points, now),
            "radar_at": local(n.at),
        });
        // A dry series says nothing the summary does not.
        if upcoming.iter().any(|p| p.precip_mm_h >= NOWCAST_WET_MM_H) {
            v["points"] = upcoming
                .iter()
                .map(|p| json!({"at": berlin_time(p.at), "precip_mm_h": p.precip_mm_h}))
                .collect();
        }
        v
    });
    let hourly: Vec<Value> = f
        .hourly
        .into_iter()
        .take(hours as usize)
        .map(|row| {
            let mut v = serde_json::to_value(&row.consensus).unwrap_or_default();
            localize(&mut v, &["at"]);
            v["n_sources"] = json!(row.n_sources);
            v["spread"] = json!({
                "temp_c": range(row.spread.temp_c),
                "precip_mm": range(row.spread.precip_mm),
                "wind_kmh": range(row.spread.wind_kmh),
                "precip_agreement_pct": row.spread.precip_agreement_pct,
            });
            if by_source {
                v["by_source"] = row
                    .by_source
                    .into_iter()
                    .map(|(k, p)| {
                        let mut p = serde_json::to_value(p).unwrap_or_default();
                        if let Some(o) = p.as_object_mut() {
                            o.remove("at");
                        }
                        (k, p)
                    })
                    .collect::<Map<_, _>>()
                    .into();
            }
            v
        })
        .collect();
    let daily: Vec<Value> = f
        .daily
        .into_iter()
        .take(days as usize)
        .map(|row| {
            let mut v = serde_json::to_value(&row.consensus).unwrap_or_default();
            v["weekday"] =
                json!(WEEKDAYS[row.consensus.date.weekday().to_monday_zero_offset() as usize]);
            for key in ["sunrise", "sunset"] {
                let parsed = v
                    .get(key)
                    .and_then(Value::as_str)
                    .and_then(|s| s.parse::<Timestamp>().ok());
                if let Some(t) = parsed {
                    v[key] = json!(berlin_time(t));
                }
            }
            v["n_sources"] = json!(row.n_sources);
            v["spread"] = json!({
                "temp_min_c": range(row.spread.temp_min_c),
                "temp_max_c": range(row.spread.temp_max_c),
                "precip_mm": range(row.spread.precip_mm),
                "precip_agreement_pct": row.spread.precip_agreement_pct,
            });
            if by_source {
                v["by_source"] = row
                    .by_source
                    .into_iter()
                    .map(|(k, p)| {
                        let mut p = serde_json::to_value(p).unwrap_or_default();
                        if let Some(o) = p.as_object_mut() {
                            o.remove("date");
                            o.remove("sunrise");
                            o.remove("sunset");
                        }
                        (k, p)
                    })
                    .collect::<Map<_, _>>()
                    .into();
            }
            v
        })
        .collect();
    let sources: Vec<Value> = f
        .sources
        .iter()
        .map(|s| {
            json!({
                "source": s.source,
                "ok": s.ok,
                "stale": s.stale,
                "fetched_at": s.fetched_at.map(local),
                "error": s.error,
            })
        })
        .collect();
    compact(json!({
        "location": location,
        "generated_at": local(now),
        "now": {"observed": observed, "forecast": current},
        "nowcast": nowcast,
        "hourly": hourly,
        "daily": daily,
        "alerts": alerts_json(&f.alerts),
        "sources": sources,
        "attribution": f.attribution.iter().map(|a| a.text).collect::<Vec<_>>(),
    }))
}

fn alerts_json(alerts: &[crate::sources::dwd::Alert]) -> Vec<Value> {
    alerts
        .iter()
        .map(|a| {
            let mut v = serde_json::to_value(a).unwrap_or_default();
            localize(&mut v, &["onset", "expires"]);
            compact(v)
        })
        .collect()
}

/// Forecast of a saved place; a place without any stored data yet (just
/// created) fetches the free sources right away.
async fn saved_forecast(app: &App, place: Place) -> AppResult<Forecast> {
    let id = place.id;
    let empty = app
        .blocking(move |c| Ok(db::snapshots(c, id)?.is_empty()))
        .await?;
    if empty {
        poller::poll_place(
            app,
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
    api::forecast_for(app, place).await
}

// ----- handlers -----------------------------------------------------------------

async fn list_places(app: &App) -> AppResult<Value> {
    let places = app.blocking(db::list_places).await?;
    Ok(json!({
        "places": places.iter().filter(|p| p.kind == "saved").map(place_json).collect::<Vec<_>>()
    }))
}

async fn get_forecast(app: &App, args: &Map<String, Value>) -> AppResult<Value> {
    let hours = count(args, "hours", 24, 48)?;
    let days = count(args, "days", 7, 10)?;
    let by_source = opt_bool(args, "by_source")?.unwrap_or(false);
    let place = args.get("place").filter(|v| !v.is_null());
    let (lat, lon) = (opt_f64(args, "lat")?, opt_f64(args, "lon")?);
    let (forecast, saved) = match (place, lat, lon) {
        (Some(place), None, None) => {
            let place = resolve_place(app, place).await?;
            (saved_forecast(app, place).await?, true)
        }
        (None, Some(lat), Some(lon)) => (api::forecast_at(app, lat, lon).await?, false),
        (Some(_), _, _) => {
            return Err(AppError::BadRequest(
                "Entweder place oder lat/lon angeben, nicht beides".into(),
            ))
        }
        _ => {
            return Err(AppError::BadRequest(
                "place oder lat und lon angeben".into(),
            ))
        }
    };
    Ok(forecast_json(forecast, saved, hours, days, by_source))
}

async fn get_alerts(app: &App, args: &Map<String, Value>) -> AppResult<Value> {
    let places = match args.get("place").filter(|v| !v.is_null()) {
        Some(place) => vec![resolve_place(app, place).await?],
        None => app
            .blocking(db::list_places)
            .await?
            .into_iter()
            .filter(|p| p.kind == "saved")
            .collect(),
    };
    let mut out = Vec::new();
    for place in places {
        let forecast = api::forecast_for(app, place.clone()).await?;
        out.push(json!({
            "place": {"id": place.id, "name": place.name},
            "alerts": alerts_json(&forecast.alerts),
        }));
    }
    Ok(json!({"places": out, "attribution": "Warnungen: Deutscher Wetterdienst"}))
}

async fn create_place(app: &App, args: &Map<String, Value>) -> AppResult<Value> {
    let name = api::check_name(opt_str(args, "name")?.unwrap_or_default())?;
    let (Some(lat), Some(lon)) = (opt_f64(args, "lat")?, opt_f64(args, "lon")?) else {
        return Err(AppError::BadRequest("lat und lon sind erforderlich".into()));
    };
    api::check_coords(lat, lon)?;
    let place = app
        .blocking(move |c| db::insert_place(c, &name, lat, lon, now_ms()))
        .await?;
    tracing::info!(place = place.id, "place created via MCP");
    Ok(json!({"place": place_json(&place)}))
}

async fn update_place(app: &App, args: &Map<String, Value>) -> AppResult<Value> {
    let place = resolve_place(app, &args["place"]).await?;
    let name = match opt_str(args, "name")? {
        Some(n) => Some(api::check_name(n)?),
        None => None,
    };
    let position =
        match args.get("position") {
            None | Some(Value::Null) => None,
            Some(v) => Some(v.as_u64().ok_or_else(|| {
                AppError::BadRequest("position muss eine ganze Zahl ab 0 sein".into())
            })? as usize),
        };
    let update = PlaceUpdate {
        name,
        notify: opt_bool(args, "notify")?,
        position,
    };
    let id = place.id;
    let updated = app
        .blocking(move |c| {
            db::update_place(c, id, &update)?;
            db::find_place(c, id)
        })
        .await?
        .ok_or(AppError::NotFound)?;
    Ok(json!({"place": place_json(&updated)}))
}

async fn delete_place(app: &App, args: &Map<String, Value>) -> AppResult<Value> {
    let place = resolve_place(app, &args["place"]).await?;
    let id = place.id;
    app.blocking(move |c| db::delete_place(c, id)).await?;
    tracing::info!(place = id, "place deleted via MCP");
    Ok(json!({"deleted": {"id": place.id, "name": place.name}}))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(min: i64) -> Timestamp {
        Timestamp::from_second(1_800_000_000 + min * 60).unwrap()
    }

    #[test]
    fn nowcast_sentences() {
        let now = at(0);
        let series = |values: &[f64]| -> Vec<(Timestamp, f64)> {
            values
                .iter()
                .enumerate()
                .map(|(i, v)| (at(i as i64 * 5), *v))
                .collect()
        };
        assert_eq!(
            nowcast_summary(&series(&[0.0, 0.0, 0.0]), now),
            "Laut Radar kein Niederschlag in den nächsten 2 Stunden."
        );
        let s = nowcast_summary(&series(&[0.0, 0.0, 1.2, 3.0]), now);
        assert!(s.starts_with("Laut Radar Niederschlag ab etwa "), "{s}");
        assert!(s.ends_with("(bis zu 3.0 mm/h)."), "{s}");
        let s = nowcast_summary(&series(&[0.5, 0.4, 0.0]), now);
        assert!(s.contains("jetzt, voraussichtlich bis etwa"), "{s}");
        let s = nowcast_summary(&series(&[0.5, 0.4]), now);
        assert!(s.contains("die nächsten 2 Stunden"), "{s}");
        // points of an older radar run before now are ignored
        let old = vec![(at(-30), 5.0), (at(0), 0.0), (at(5), 0.0)];
        assert_eq!(
            nowcast_summary(&old, now),
            "Laut Radar kein Niederschlag in den nächsten 2 Stunden."
        );
        assert_eq!(nowcast_summary(&[], now), "Keine aktuellen Radardaten.");
    }

    #[test]
    fn compact_drops_nulls() {
        assert_eq!(
            compact(json!({"a": null, "b": [{"c": null, "d": 1}]})),
            json!({"b": [{"d": 1}]})
        );
    }

    #[test]
    fn schemas_are_objects_without_top_level_combinators() {
        for def in definitions() {
            assert_eq!(def.input_schema["type"], "object", "{}", def.name);
            assert!(def.input_schema.get("oneOf").is_none());
            assert!(def.input_schema.get("anyOf").is_none());
        }
    }
}
