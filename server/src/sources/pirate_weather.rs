//! Pirate Weather (`/forecast/{key}/{lat},{lon}`), Dark-Sky-compatible.
//!
//! Requested with `units=ca`: °C, km/h, mm/h, hPa; humidity, cloud cover
//! and probability as 0–1. `precipAccumulation` is centimetres and mixes
//! snow depth with liquid, so precipitation comes from `precipIntensity`
//! (liquid equivalent, mm/h): per hour as is, per day × 24 (it is the day's
//! mean). `time` is the hour start; daily `time` is local midnight. Day 0
//! only covers the rest of today and is left out. `windBearing` is the
//! direction the wind comes from (as in Dark Sky, despite the docs).

use jiff::Timestamp;
use serde::Deserialize;
use url::Url;

use super::bright_sky::icon_condition;
use super::{berlin, get_bytes, DayPoint, HourPoint, SourceData, SourceError, SourceId};

pub async fn fetch(
    http: &reqwest::Client,
    base: &Url,
    key: &str,
    lat: f64,
    lon: f64,
) -> Result<Vec<SourceData>, SourceError> {
    let mut url = base
        .join(&format!("forecast/{key}/{lat},{lon}"))
        .map_err(|_| SourceError::Http("ungültige Pirate-Weather-URL".into()))?;
    url.query_pairs_mut()
        .append_pair("units", "ca")
        .append_pair("exclude", "currently,minutely,alerts");
    // get_bytes strips the URL (with the key) from its errors.
    Ok(vec![parse(&get_bytes(http, url).await?)?])
}

#[derive(Deserialize)]
struct Body {
    flags: Flags,
    hourly: Block,
    daily: Block,
}

#[derive(Deserialize)]
struct Flags {
    units: String,
}

#[derive(Deserialize)]
struct Block {
    data: Vec<Point>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Point {
    time: i64,
    icon: Option<String>,
    precip_intensity: Option<f64>,
    precip_probability: Option<f64>,
    temperature: Option<f64>,
    apparent_temperature: Option<f64>,
    temperature_min: Option<f64>,
    temperature_max: Option<f64>,
    humidity: Option<f64>,
    pressure: Option<f64>,
    wind_speed: Option<f64>,
    wind_gust: Option<f64>,
    wind_bearing: Option<f64>,
    cloud_cover: Option<f64>,
    sunrise_time: Option<i64>,
    sunset_time: Option<i64>,
}

fn pct(v: Option<f64>) -> Option<f64> {
    v.map(|v| (v * 100.0).round())
}

fn ts(secs: i64) -> Option<Timestamp> {
    Timestamp::from_second(secs).ok()
}

pub fn parse(body: &[u8]) -> Result<SourceData, SourceError> {
    let body: Body = serde_json::from_slice(body).map_err(|e| SourceError::Parse(e.to_string()))?;
    // Any other unit system would silently be off by 3.6 (si) or worse (us).
    if body.flags.units != "ca" {
        return Err(SourceError::Parse(format!(
            "Einheiten {} statt ca",
            body.flags.units
        )));
    }
    let hourly = body
        .hourly
        .data
        .iter()
        .filter_map(|p| {
            let precip_mm = p.precip_intensity?;
            Some(HourPoint {
                at: ts(p.time)?,
                temp_c: p.temperature?,
                feels_like_c: p.apparent_temperature,
                precip_mm,
                precip_prob_pct: pct(p.precip_probability),
                wind_kmh: p.wind_speed?,
                gust_kmh: p.wind_gust,
                wind_dir_deg: p.wind_bearing,
                cloud_pct: pct(p.cloud_cover),
                humidity_pct: pct(p.humidity),
                pressure_hpa: p.pressure,
                condition: icon_condition(p.icon.as_deref()?, precip_mm)?,
                is_day: p.icon.as_deref().and_then(|i| {
                    i.ends_with("-day")
                        .then_some(true)
                        .or(i.ends_with("-night").then_some(false))
                }),
            })
        })
        .collect();
    let tz = berlin();
    let daily = body
        .daily
        .data
        .iter()
        .skip(1)
        .filter_map(|p| {
            let precip_mm = (p.precip_intensity? * 24.0 * 10.0).round() / 10.0;
            Some(DayPoint {
                date: ts(p.time)?.to_zoned(tz.clone()).date(),
                temp_min_c: p.temperature_min?,
                temp_max_c: p.temperature_max?,
                precip_mm,
                precip_prob_pct: pct(p.precip_probability),
                // Daily windSpeed is a mean, not a maximum.
                wind_max_kmh: None,
                gust_max_kmh: p.wind_gust,
                condition: icon_condition(p.icon.as_deref()?, 0.0)?,
                sunrise: p.sunrise_time.and_then(ts),
                sunset: p.sunset_time.and_then(ts),
            })
        })
        .collect();
    Ok(SourceData {
        source: SourceId::PirateWeather,
        hourly,
        daily,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sources::Condition;
    use jiff::civil::date;

    // Synthetic: built from the documented schema (units=ca).
    const FIXTURE: &[u8] = include_bytes!("../../tests/fixtures/pirate_weather/forecast.json");

    #[test]
    fn parses_ca_units() {
        let data = parse(FIXTURE).unwrap();
        assert_eq!(data.hourly.len(), 3);
        let h = &data.hourly[0];
        assert_eq!(h.temp_c, 6.1);
        assert_eq!(h.wind_kmh, 14.0);
        assert_eq!(h.humidity_pct, Some(90.0));
        assert_eq!(h.condition, Condition::Cloudy);
        // Day 0 (today, partial) is dropped; day 1 remains.
        assert_eq!(data.daily.len(), 1);
        let d = &data.daily[0];
        assert_eq!(d.date, date(2026, 11, 11));
        assert!(d.temp_min_c < d.temp_max_c);
        assert_eq!(d.wind_max_kmh, None);
    }

    #[test]
    fn rejects_other_units() {
        let mut v: serde_json::Value = serde_json::from_slice(FIXTURE).unwrap();
        v["flags"]["units"] = "si".into();
        assert!(matches!(
            parse(&serde_json::to_vec(&v).unwrap()),
            Err(SourceError::Parse(_))
        ));
    }
}
