//! Bright Sky beyond the forecast: SYNOP observation (`/current_weather`),
//! DWD warnings (`/alerts`) and radar nowcast (`/radar`).

use jiff::Timestamp;
use serde::{Deserialize, Serialize};
use url::Url;

use super::bright_sky::icon_condition;
use super::{get_bytes, Condition, SourceError};

/// Latest station observation near the place.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Observation {
    pub station: Option<String>,
    pub distance_m: Option<f64>,
    pub at: Timestamp,
    pub temp_c: Option<f64>,
    pub humidity_pct: Option<f64>,
    pub wind_kmh: Option<f64>,
    pub gust_kmh: Option<f64>,
    pub wind_dir_deg: Option<f64>,
    pub pressure_hpa: Option<f64>,
    pub precip_mm_1h: Option<f64>,
    pub cloud_pct: Option<f64>,
    pub visibility_m: Option<f64>,
    pub condition: Option<Condition>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Alert {
    pub id: String,
    pub severity: String,
    pub event: String,
    pub headline: String,
    pub description: String,
    pub instruction: Option<String>,
    pub onset: Timestamp,
    pub expires: Option<Timestamp>,
    pub source: String,
}

impl Alert {
    pub fn severity_rank(&self) -> u8 {
        match self.severity.as_str() {
            "extreme" => 4,
            "severe" => 3,
            "moderate" => 2,
            _ => 1,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NowcastPoint {
    pub at: Timestamp,
    pub precip_mm_h: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Nowcast {
    pub source: String,
    /// Time of the radar analysis the forecast starts from.
    pub at: Timestamp,
    pub points: Vec<NowcastPoint>,
}

fn endpoint(base: &Url, path: &str, lat: f64, lon: f64) -> Result<Url, SourceError> {
    let mut url = base
        .join(path)
        .map_err(|e| SourceError::Http(e.to_string()))?;
    url.query_pairs_mut()
        .append_pair("lat", &lat.to_string())
        .append_pair("lon", &lon.to_string());
    Ok(url)
}

fn parse_err(e: impl std::fmt::Display) -> SourceError {
    SourceError::Parse(e.to_string())
}

// --- /current_weather -------------------------------------------------------

#[derive(Deserialize)]
struct CurrentBody {
    weather: CurrentRaw,
    sources: Vec<StationRaw>,
}

#[derive(Deserialize)]
struct StationRaw {
    id: i64,
    station_name: Option<String>,
    distance: Option<f64>,
}

#[derive(Deserialize)]
struct CurrentRaw {
    timestamp: Timestamp,
    source_id: i64,
    temperature: Option<f64>,
    relative_humidity: Option<f64>,
    wind_speed_10: Option<f64>,
    wind_gust_speed_10: Option<f64>,
    wind_direction_10: Option<f64>,
    pressure_msl: Option<f64>,
    precipitation_60: Option<f64>,
    cloud_cover: Option<f64>,
    visibility: Option<f64>,
    icon: Option<String>,
}

pub async fn fetch_observation(
    http: &reqwest::Client,
    base: &Url,
    lat: f64,
    lon: f64,
) -> Result<Observation, SourceError> {
    parse_observation(&get_bytes(http, endpoint(base, "current_weather", lat, lon)?).await?)
}

pub fn parse_observation(body: &[u8]) -> Result<Observation, SourceError> {
    let body: CurrentBody = serde_json::from_slice(body).map_err(parse_err)?;
    let w = body.weather;
    let station = body.sources.iter().find(|s| s.id == w.source_id);
    let precip = w.precipitation_60.unwrap_or(0.0);
    Ok(Observation {
        station: station.and_then(|s| s.station_name.clone()),
        distance_m: station.and_then(|s| s.distance),
        at: w.timestamp,
        temp_c: w.temperature,
        humidity_pct: w.relative_humidity,
        wind_kmh: w.wind_speed_10,
        gust_kmh: w.wind_gust_speed_10,
        wind_dir_deg: w.wind_direction_10,
        pressure_hpa: w.pressure_msl,
        precip_mm_1h: w.precipitation_60,
        cloud_pct: w.cloud_cover,
        visibility_m: w.visibility,
        condition: w.icon.as_deref().and_then(|i| icon_condition(i, precip)),
    })
}

// --- /alerts -------------------------------------------------------------------

#[derive(Deserialize)]
struct AlertsBody {
    alerts: Vec<AlertRaw>,
}

#[derive(Deserialize)]
struct AlertRaw {
    alert_id: serde_json::Value,
    severity: Option<String>,
    status: Option<String>,
    event_de: Option<String>,
    headline_de: Option<String>,
    description_de: Option<String>,
    instruction_de: Option<String>,
    onset: Timestamp,
    expires: Option<Timestamp>,
}

pub async fn fetch_alerts(
    http: &reqwest::Client,
    base: &Url,
    lat: f64,
    lon: f64,
) -> Result<Vec<Alert>, SourceError> {
    parse_alerts(&get_bytes(http, endpoint(base, "alerts", lat, lon)?).await?)
}

/// Actual (not test/exercise) warnings, most severe first.
pub fn parse_alerts(body: &[u8]) -> Result<Vec<Alert>, SourceError> {
    let body: AlertsBody = serde_json::from_slice(body).map_err(parse_err)?;
    let mut alerts: Vec<Alert> = body
        .alerts
        .into_iter()
        .filter(|a| a.status.as_deref().is_none_or(|s| s == "actual"))
        .map(|a| Alert {
            id: match a.alert_id {
                serde_json::Value::String(s) => s,
                other => other.to_string(),
            },
            severity: a.severity.unwrap_or_else(|| "minor".into()),
            event: a.event_de.unwrap_or_default(),
            headline: a.headline_de.unwrap_or_default(),
            description: a.description_de.unwrap_or_default(),
            instruction: a.instruction_de.filter(|s| !s.trim().is_empty()),
            onset: a.onset,
            expires: a.expires,
            source: "dwd".into(),
        })
        .collect();
    alerts.sort_by(|a, b| {
        b.severity_rank()
            .cmp(&a.severity_rank())
            .then(a.onset.cmp(&b.onset))
    });
    Ok(alerts)
}

// --- /radar ----------------------------------------------------------------------

#[derive(Deserialize)]
struct RadarBody {
    radar: Vec<RadarFrame>,
    latlon_position: Position,
}

#[derive(Deserialize)]
struct Position {
    x: f64,
    y: f64,
}

#[derive(Deserialize)]
struct RadarFrame {
    timestamp: Timestamp,
    /// 0.01 mm per 5 minutes, rows × columns around the place.
    precipitation_5: Vec<Vec<f64>>,
}

pub async fn fetch_nowcast(
    http: &reqwest::Client,
    base: &Url,
    lat: f64,
    lon: f64,
) -> Result<Nowcast, SourceError> {
    let mut url = endpoint(base, "radar", lat, lon)?;
    url.query_pairs_mut()
        .append_pair("distance", "2000")
        .append_pair("format", "plain");
    parse_nowcast(&get_bytes(http, url).await?)
}

/// Intensity at the place's pixel per 5-minute frame (mm/h).
pub fn parse_nowcast(body: &[u8]) -> Result<Nowcast, SourceError> {
    let body: RadarBody = serde_json::from_slice(body).map_err(parse_err)?;
    let (row, col) = (
        body.latlon_position.y.round() as usize,
        body.latlon_position.x.round() as usize,
    );
    let points: Vec<NowcastPoint> = body
        .radar
        .iter()
        .map(|f| {
            let v = f
                .precipitation_5
                .get(row)
                .and_then(|r| r.get(col))
                .copied()
                .unwrap_or(0.0);
            NowcastPoint {
                at: f.timestamp,
                precip_mm_h: (v * 0.01 * 12.0 * 100.0).round() / 100.0,
            }
        })
        .collect();
    let at = points
        .first()
        .map(|p| p.at)
        .ok_or_else(|| SourceError::Parse("keine Radarbilder".into()))?;
    Ok(Nowcast {
        source: "bright_sky:radar".into(),
        at,
        points,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn observation_names_its_station() {
        let o = parse_observation(include_bytes!(
            "../../tests/fixtures/bright_sky/current_weather.json"
        ))
        .unwrap();
        assert_eq!(o.station.as_deref(), Some("Uelzen"));
        assert_eq!(o.distance_m, Some(3383.0));
        assert_eq!(o.temp_c, Some(8.2));
        assert_eq!(o.condition, Some(Condition::PartlyCloudy));
    }

    #[test]
    fn alerts_in_german() {
        let a = parse_alerts(include_bytes!(
            "../../tests/fixtures/bright_sky/alerts.json"
        ))
        .unwrap();
        assert_eq!(a.len(), 1);
        assert_eq!(a[0].event, "DAUERREGEN");
        assert_eq!(a[0].severity, "moderate");
        assert_eq!(a[0].id, "3051010");
        assert!(a[0].instruction.is_some());
        let empty = br#"{"alerts":[],"location":null}"#;
        assert!(parse_alerts(empty).unwrap().is_empty());
    }

    #[test]
    fn nowcast_reads_the_place_pixel() {
        // Fixture: 25 frames from 12:35 local; the centre pixel (2,2) gets
        // 25 (0.25 mm/5 min = 3 mm/h) from 13:10 on.
        let n =
            parse_nowcast(include_bytes!("../../tests/fixtures/bright_sky/radar.json")).unwrap();
        assert_eq!(n.points.len(), 25);
        assert_eq!(n.at.to_string(), "2026-11-09T11:35:00Z");
        assert_eq!(n.points[6].precip_mm_h, 0.0);
        assert_eq!(n.points[7].precip_mm_h, 3.0);
    }
}
