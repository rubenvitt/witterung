//! Weather sources. Each upstream has its own adapter module that fetches and
//! normalizes into [`HourPoint`]/[`DayPoint`]; nothing outside this module
//! knows upstream formats.
//!
//! Hour convention: `at` is the start of the hour. Instantaneous values
//! (temperature, wind) hold at `at`; accumulated values (precipitation, its
//! probability, the condition) cover `at .. at + 1h`. Upstreams that label
//! sums with the end of the hour are shifted by their adapter.

pub mod bright_sky;
pub mod dwd;
pub mod open_meteo;
pub mod pirate_weather;
pub mod weatherkit;

use jiff::civil::Date;
use jiff::tz::TimeZone;
use jiff::Timestamp;
use serde::{Deserialize, Serialize};
use url::Url;

/// One forecast series. Open-Meteo yields several from a single request.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum SourceId {
    #[serde(rename = "weatherkit")]
    WeatherKit,
    #[serde(rename = "open_meteo:icon_d2")]
    IconD2,
    #[serde(rename = "open_meteo:icon_eu")]
    IconEu,
    #[serde(rename = "open_meteo:ecmwf_ifs")]
    EcmwfIfs,
    #[serde(rename = "open_meteo:gfs")]
    Gfs,
    #[serde(rename = "bright_sky:mosmix")]
    Mosmix,
    #[serde(rename = "pirate_weather")]
    PirateWeather,
}

impl SourceId {
    pub fn as_str(self) -> &'static str {
        match self {
            SourceId::WeatherKit => "weatherkit",
            SourceId::IconD2 => "open_meteo:icon_d2",
            SourceId::IconEu => "open_meteo:icon_eu",
            SourceId::EcmwfIfs => "open_meteo:ecmwf_ifs",
            SourceId::Gfs => "open_meteo:gfs",
            SourceId::Mosmix => "bright_sky:mosmix",
            SourceId::PirateWeather => "pirate_weather",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Condition {
    Clear,
    PartlyCloudy,
    Cloudy,
    Fog,
    Drizzle,
    Rain,
    HeavyRain,
    Snow,
    Sleet,
    Hail,
    Thunderstorm,
    Wind,
}

impl Condition {
    /// Rank among precipitation conditions (higher = more severe); `None`
    /// for dry ones.
    fn wet_rank(self) -> Option<u8> {
        Some(match self {
            Condition::Drizzle => 1,
            Condition::Rain => 2,
            Condition::Sleet => 3,
            Condition::Snow => 4,
            Condition::HeavyRain => 5,
            Condition::Hail => 6,
            Condition::Thunderstorm => 7,
            _ => return None,
        })
    }
}

/// WMO threshold for heavy rain (mm/h).
pub const HEAVY_RAIN_MM_H: f64 = 7.6;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HourPoint {
    pub at: Timestamp,
    pub temp_c: f64,
    pub feels_like_c: Option<f64>,
    pub precip_mm: f64,
    pub precip_prob_pct: Option<f64>,
    pub wind_kmh: f64,
    pub gust_kmh: Option<f64>,
    pub wind_dir_deg: Option<f64>,
    pub cloud_pct: Option<f64>,
    pub humidity_pct: Option<f64>,
    pub pressure_hpa: Option<f64>,
    pub condition: Condition,
    /// `None` when the upstream does not say (e.g. a "cloudy" icon).
    pub is_day: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DayPoint {
    /// Local date in Europe/Berlin.
    pub date: Date,
    pub temp_min_c: f64,
    pub temp_max_c: f64,
    pub precip_mm: f64,
    pub precip_prob_pct: Option<f64>,
    /// `None` where the upstream only has a daily mean (WeatherKit, Pirate Weather).
    pub wind_max_kmh: Option<f64>,
    pub gust_max_kmh: Option<f64>,
    pub condition: Condition,
    pub sunrise: Option<Timestamp>,
    pub sunset: Option<Timestamp>,
}

/// Normalized forecast of one source for one place.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SourceData {
    pub source: SourceId,
    pub hourly: Vec<HourPoint>,
    pub daily: Vec<DayPoint>,
}

#[derive(Debug, thiserror::Error)]
pub enum SourceError {
    #[error("Abruf fehlgeschlagen: {0}")]
    Http(String),
    #[error("Antwort nicht lesbar: {0}")]
    Parse(String),
}

/// Base URLs of the upstreams; tests point them at a local mock server.
#[derive(Debug, Clone)]
pub struct Endpoints {
    pub open_meteo: Url,
    pub bright_sky: Url,
    pub weatherkit: Url,
    pub pirate_weather: Url,
}

impl Default for Endpoints {
    fn default() -> Self {
        let url = |s: &str| Url::parse(s).expect("static URL is valid");
        Self {
            open_meteo: url("https://api.open-meteo.com/v1/"),
            bright_sky: url("https://api.brightsky.dev/"),
            weatherkit: url("https://weatherkit.apple.com/api/v1/"),
            pirate_weather: url("https://api.pirateweather.net/"),
        }
    }
}

/// `HH:MM` in Europe/Berlin.
pub fn berlin_time(t: Timestamp) -> String {
    t.to_zoned(berlin()).strftime("%H:%M").to_string()
}

/// The local time zone for day boundaries (bundled tzdb, no system files needed).
pub fn berlin() -> TimeZone {
    TimeZone::get("Europe/Berlin").expect("Europe/Berlin is in the bundled tzdb")
}

pub(crate) async fn get_bytes(http: &reqwest::Client, url: Url) -> Result<Vec<u8>, SourceError> {
    let response = http
        .get(url)
        .send()
        .await
        .map_err(|e| SourceError::Http(e.without_url().to_string()))?;
    let status = response.status();
    if !status.is_success() {
        return Err(SourceError::Http(format!("HTTP {status}")));
    }
    let body = response
        .bytes()
        .await
        .map_err(|e| SourceError::Http(e.without_url().to_string()))?;
    Ok(body.to_vec())
}

/// Daily condition from hourly ones: a wet day (≥ 1 mm) shows its most
/// severe precipitation, otherwise the most frequent dry condition.
pub fn day_condition(hours: &[Condition], precip_mm: f64) -> Condition {
    if precip_mm >= 1.0 {
        if let Some(c) = hours.iter().copied().max_by_key(|c| c.wet_rank()) {
            if c.wet_rank().is_some() {
                return c;
            }
        }
    }
    let mut counts: Vec<(Condition, usize)> = Vec::new();
    for &c in hours.iter().filter(|c| c.wet_rank().is_none()) {
        match counts.iter_mut().find(|(k, _)| *k == c) {
            Some((_, n)) => *n += 1,
            None => counts.push((c, 1)),
        }
    }
    // Ties go to the first seen; `max_by_key` would pick the last.
    counts
        .iter()
        .fold(
            None,
            |best: Option<(Condition, usize)>, &(c, n)| match best {
                Some((_, m)) if m >= n => best,
                _ => Some((c, n)),
            },
        )
        .map_or(Condition::Cloudy, |(c, _)| c)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn day_condition_prefers_severe_precip_on_wet_days() {
        use Condition::*;
        let hours = [Cloudy, Rain, Thunderstorm, Cloudy, Cloudy];
        assert_eq!(day_condition(&hours, 5.0), Thunderstorm);
        // Below 1 mm a shower does not make the day rainy.
        assert_eq!(day_condition(&hours, 0.4), Cloudy);
        assert_eq!(day_condition(&[Clear, Clear, Cloudy], 0.0), Clear);
        assert_eq!(day_condition(&[], 0.0), Cloudy);
    }

    #[test]
    fn source_ids_serialize_as_documented() {
        let json = serde_json::to_string(&SourceId::IconD2).unwrap();
        assert_eq!(json, format!("\"{}\"", SourceId::IconD2.as_str()));
    }
}
