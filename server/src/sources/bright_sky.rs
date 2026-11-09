//! Bright Sky (DWD open data): MOSMIX forecast from `/weather`.
//!
//! `/weather` mixes station observations (past hours) with the MOSMIX
//! forecast in one list; only entries whose `source_id` belongs to a source
//! of type `forecast` count. Sums and the condition refer to the PRECEDING
//! hour and are shifted to the hour start (see `sources` module docs).
//! Bright Sky has no daily values: days are aggregated here, complete local
//! days only. Default units are already metric (km/h, mm, hPa, %).
//!
//! Parser shape taken from lagemonitor (`src/sources/weather.rs`).

use std::collections::HashSet;

use jiff::civil::Date;
use jiff::{Timestamp, ToSpan};
use serde::Deserialize;
use url::Url;

use super::{
    berlin, day_condition, get_bytes, Condition, DayPoint, HourPoint, SourceData, SourceError,
    SourceId, HEAVY_RAIN_MM_H,
};

pub const FORECAST_DAYS: i64 = 10;

#[derive(Deserialize)]
struct Body {
    weather: Vec<Raw>,
    sources: Vec<RawSource>,
}

#[derive(Deserialize)]
struct RawSource {
    id: i64,
    observation_type: String,
}

// Missing values come as `null`: everything but the timestamp is optional.
#[derive(Deserialize)]
struct Raw {
    timestamp: Timestamp,
    source_id: i64,
    temperature: Option<f64>,
    precipitation: Option<f64>,
    precipitation_probability: Option<f64>,
    wind_speed: Option<f64>,
    wind_gust_speed: Option<f64>,
    wind_direction: Option<f64>,
    cloud_cover: Option<f64>,
    relative_humidity: Option<f64>,
    pressure_msl: Option<f64>,
    icon: Option<String>,
}

pub fn url(base: &Url, lat: f64, lon: f64, now: Timestamp) -> Result<Url, SourceError> {
    let tz = berlin();
    let start = now
        .to_zoned(tz.clone())
        .start_of_day()
        .map_err(|e| SourceError::Http(e.to_string()))?;
    let end = start
        .checked_add(FORECAST_DAYS.days())
        .map_err(|e| SourceError::Http(e.to_string()))?;
    let mut url = base
        .join("weather")
        .map_err(|e| SourceError::Http(e.to_string()))?;
    url.query_pairs_mut()
        .append_pair("lat", &lat.to_string())
        .append_pair("lon", &lon.to_string())
        .append_pair("date", &start.timestamp().to_string())
        .append_pair("last_date", &end.timestamp().to_string())
        .append_pair("tz", "Europe/Berlin");
    Ok(url)
}

pub async fn fetch(
    http: &reqwest::Client,
    base: &Url,
    lat: f64,
    lon: f64,
    now: Timestamp,
) -> Result<Vec<SourceData>, SourceError> {
    let body = get_bytes(http, url(base, lat, lon, now)?).await?;
    Ok(vec![parse(&body)?])
}

pub fn parse(body: &[u8]) -> Result<SourceData, SourceError> {
    let body: Body = serde_json::from_slice(body).map_err(|e| SourceError::Parse(e.to_string()))?;
    let forecast: HashSet<i64> = body
        .sources
        .iter()
        .filter(|s| s.observation_type == "forecast")
        .map(|s| s.id)
        .collect();
    let mut entries: Vec<&Raw> = body
        .weather
        .iter()
        .filter(|w| forecast.contains(&w.source_id))
        .collect();
    entries.sort_by_key(|w| w.timestamp);

    let mut hourly = Vec::new();
    for pair in entries.windows(2) {
        let (now, next) = (pair[0], pair[1]);
        // A gap in the series would attach the wrong hour's sum.
        if next.timestamp.duration_since(now.timestamp).as_secs() != 3600 {
            continue;
        }
        let (Some(temp_c), Some(wind_kmh), Some(precip_mm), Some(icon)) = (
            now.temperature,
            now.wind_speed,
            next.precipitation,
            next.icon.as_deref(),
        ) else {
            continue;
        };
        let Some(condition) = icon_condition(icon, precip_mm) else {
            continue;
        };
        hourly.push(HourPoint {
            at: now.timestamp,
            temp_c,
            feels_like_c: None,
            precip_mm,
            precip_prob_pct: next.precipitation_probability,
            wind_kmh,
            // Gusts are the maximum of the preceding hour, like the sums.
            gust_kmh: next.wind_gust_speed,
            wind_dir_deg: now.wind_direction,
            cloud_pct: now.cloud_cover,
            humidity_pct: now.relative_humidity,
            pressure_hpa: now.pressure_msl,
            condition,
            is_day: now.icon.as_deref().and_then(icon_is_day),
        });
    }
    let daily = aggregate_days(&hourly)?;
    Ok(SourceData {
        source: SourceId::Mosmix,
        hourly,
        daily,
    })
}

/// Days from hours; a day appears only if every local hour is present
/// (23 or 25 on DST days).
fn aggregate_days(hourly: &[HourPoint]) -> Result<Vec<DayPoint>, SourceError> {
    let tz = berlin();
    let mut days: Vec<(Date, Vec<&HourPoint>)> = Vec::new();
    for p in hourly {
        let date = p.at.to_zoned(tz.clone()).date();
        match days.last_mut() {
            Some((d, hours)) if *d == date => hours.push(p),
            _ => days.push((date, vec![p])),
        }
    }
    let mut out = Vec::new();
    for (date, hours) in days {
        let start = date
            .to_zoned(tz.clone())
            .map_err(|e| SourceError::Parse(e.to_string()))?;
        let end = date
            .tomorrow()
            .and_then(|d| d.to_zoned(tz.clone()))
            .map_err(|e| SourceError::Parse(e.to_string()))?;
        let expected = end.timestamp().duration_since(start.timestamp()).as_secs() / 3600;
        if hours.len() as i64 != expected {
            continue;
        }
        let fold = |f: fn(&HourPoint) -> f64, pick: fn(f64, f64) -> f64| {
            hours.iter().map(|p| f(p)).reduce(pick).unwrap_or(f64::NAN)
        };
        let precip_mm = hours.iter().map(|p| p.precip_mm).sum::<f64>();
        let conditions: Vec<Condition> = hours.iter().map(|p| p.condition).collect();
        out.push(DayPoint {
            date,
            temp_min_c: fold(|p| p.temp_c, f64::min),
            temp_max_c: fold(|p| p.temp_c, f64::max),
            precip_mm: (precip_mm * 10.0).round() / 10.0,
            precip_prob_pct: hours
                .iter()
                .filter_map(|p| p.precip_prob_pct)
                .reduce(f64::max),
            wind_max_kmh: Some(fold(|p| p.wind_kmh, f64::max)),
            gust_max_kmh: hours.iter().filter_map(|p| p.gust_kmh).reduce(f64::max),
            condition: day_condition(&conditions, precip_mm),
            sunrise: None,
            sunset: None,
        });
    }
    Ok(out)
}

/// Bright Sky icons: clear-day/-night, partly-cloudy-day/-night, cloudy,
/// fog, wind, rain, sleet, snow, hail, thunderstorm.
pub fn icon_condition(icon: &str, precip_mm_h: f64) -> Option<Condition> {
    use Condition::*;
    Some(match icon {
        "clear-day" | "clear-night" => Clear,
        "partly-cloudy-day" | "partly-cloudy-night" => PartlyCloudy,
        "cloudy" => Cloudy,
        "fog" => Fog,
        "wind" => Wind,
        "rain" if precip_mm_h >= HEAVY_RAIN_MM_H => HeavyRain,
        "rain" => Rain,
        "sleet" => Sleet,
        "snow" => Snow,
        "hail" => Hail,
        "thunderstorm" => Thunderstorm,
        _ => return None,
    })
}

fn icon_is_day(icon: &str) -> Option<bool> {
    if icon.ends_with("-day") {
        Some(true)
    } else if icon.ends_with("-night") {
        Some(false)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use jiff::civil::date;

    const FIXTURE: &[u8] = include_bytes!("../../tests/fixtures/bright_sky/weather.json");

    #[test]
    fn keeps_only_mosmix_entries() {
        // The fixture holds 11 + 1 station observations before the 37
        // MOSMIX hours; observations must not show up as forecast.
        let data = parse(FIXTURE).unwrap();
        assert_eq!(data.source, SourceId::Mosmix);
        assert_eq!(data.hourly.len(), 36);
        assert_eq!(data.hourly[0].at.to_string(), "2026-11-09T11:00:00Z");
        assert_eq!(data.hourly[0].temp_c, 6.2);
        // The sum and icon of 13:00 local describe 12–13 and land at 12:00.
        assert_eq!(data.hourly[0].condition, Condition::PartlyCloudy);
        assert_eq!(data.hourly[0].is_day, None);
        assert_eq!(data.hourly[1].is_day, Some(true));
    }

    #[test]
    fn aggregates_complete_local_days_only() {
        let data = parse(FIXTURE).unwrap();
        // 9 Nov starts at noon (observations before) → incomplete.
        assert_eq!(data.daily.len(), 1);
        let day = &data.daily[0];
        assert_eq!(day.date, date(2026, 11, 10));
        assert_eq!((day.temp_min_c, day.temp_max_c), (1.5, 5.9));
        assert_eq!(day.precip_mm, 0.0);
        assert_eq!(day.condition, Condition::Cloudy);
        assert_eq!(day.sunrise, None);
    }

    #[test]
    fn days_are_23_hours_at_dst_start() {
        // 2027-03-28: clocks jump from 02:00 to 03:00.
        let start: Timestamp = "2027-03-27T23:00:00Z".parse().unwrap();
        let hours: Vec<HourPoint> = (0..23)
            .map(|i| HourPoint {
                at: start + (i as i64).hours(),
                temp_c: i as f64,
                feels_like_c: None,
                precip_mm: 0.0,
                precip_prob_pct: None,
                wind_kmh: 5.0,
                gust_kmh: None,
                wind_dir_deg: None,
                cloud_pct: None,
                humidity_pct: None,
                pressure_hpa: None,
                condition: Condition::Clear,
                is_day: None,
            })
            .collect();
        let days = aggregate_days(&hours).unwrap();
        assert_eq!(days.len(), 1);
        assert_eq!(days[0].date, date(2027, 3, 28));
        assert!(aggregate_days(&hours[1..]).unwrap().is_empty());
    }

    #[test]
    fn broken_json_is_a_parse_error() {
        assert!(matches!(parse(b"{}"), Err(SourceError::Parse(_))));
    }

    #[test]
    fn url_starts_at_local_midnight() {
        let base = Url::parse("https://api.brightsky.dev/").unwrap();
        let now: Timestamp = "2026-11-09T10:30:00Z".parse().unwrap();
        let url = url(&base, 52.9656, 10.5594, now).unwrap();
        let q: Vec<(String, String)> = url.query_pairs().into_owned().collect();
        assert!(q.contains(&("date".into(), "2026-11-08T23:00:00Z".into())));
        assert!(q.contains(&("last_date".into(), "2026-11-18T23:00:00Z".into())));
    }
}
