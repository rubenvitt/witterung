//! Open-Meteo `/v1/forecast`: several models in one request; every field
//! comes back suffixed with the model ID (`temperature_2m_icon_d2_…`).
//!
//! Open-Meteo labels precipitation, its probability and the weather code
//! with the END of the hour (“preceding hour”); the adapter shifts them to
//! the hour start (see `sources` module docs). A model returns `null` beyond
//! its horizon and for days it does not fully cover: such hours and days are
//! left out, never filled with 0.
//!
//! Open-Meteo applies ONE fixed UTC offset to the whole response (the one
//! valid when the request is made), even across a DST change: daily `time`
//! values are midnights in that offset. Their date therefore comes from
//! `utc_offset_seconds`, not from the tz rules; on the far side of a DST
//! change a daily aggregate covers 01:00–01:00 (or 23:00–23:00) local time.

use std::collections::HashMap;

use jiff::Timestamp;
use serde::Deserialize;
use url::Url;

use jiff::tz::{Offset, TimeZone};

use super::{
    get_bytes, Condition, DayPoint, HourPoint, SourceData, SourceError, SourceId, HEAVY_RAIN_MM_H,
};

/// Open-Meteo model IDs per source.
pub const MODELS: &[(SourceId, &str)] = &[
    (SourceId::IconD2, "dwd_icon_d2_native"),
    (SourceId::IconEu, "dwd_icon_eu_native"),
    (SourceId::EcmwfIfs, "ecmwf_ifs"),
    (SourceId::Gfs, "gfs_seamless"),
];

const HOURLY: &[&str] = &[
    "temperature_2m",
    "apparent_temperature",
    "precipitation",
    "precipitation_probability",
    "weather_code",
    "wind_speed_10m",
    "wind_gusts_10m",
    "wind_direction_10m",
    "cloud_cover",
    "relative_humidity_2m",
    "pressure_msl",
    "is_day",
];

const DAILY: &[&str] = &[
    "weather_code",
    "temperature_2m_max",
    "temperature_2m_min",
    "precipitation_sum",
    "precipitation_probability_max",
    "wind_speed_10m_max",
    "wind_gusts_10m_max",
    "sunrise",
    "sunset",
];

pub const FORECAST_DAYS: u32 = 10;

#[derive(Deserialize)]
struct Body {
    utc_offset_seconds: i32,
    hourly: HashMap<String, Vec<Option<f64>>>,
    daily: HashMap<String, Vec<Option<f64>>>,
}

/// Weighted calls one request costs: more than 10 variables or 2 weeks
/// count fractionally; every model multiplies the variables.
pub fn request_weight() -> f64 {
    let variables = ((HOURLY.len() + DAILY.len()) * MODELS.len()) as f64;
    (variables / 10.0).max(1.0) * (f64::from(FORECAST_DAYS) / 14.0).max(1.0)
}

pub fn url(base: &Url, lat: f64, lon: f64) -> Result<Url, SourceError> {
    let mut url = base
        .join("forecast")
        .map_err(|e| SourceError::Http(e.to_string()))?;
    let models: Vec<&str> = MODELS.iter().map(|(_, m)| *m).collect();
    url.query_pairs_mut()
        .append_pair("latitude", &lat.to_string())
        .append_pair("longitude", &lon.to_string())
        .append_pair("hourly", &HOURLY.join(","))
        .append_pair("daily", &DAILY.join(","))
        .append_pair("models", &models.join(","))
        .append_pair("timezone", "Europe/Berlin")
        .append_pair("timeformat", "unixtime")
        .append_pair("forecast_days", &FORECAST_DAYS.to_string())
        .append_pair("wind_speed_unit", "kmh");
    Ok(url)
}

pub async fn fetch(
    http: &reqwest::Client,
    base: &Url,
    lat: f64,
    lon: f64,
) -> Result<Vec<SourceData>, SourceError> {
    parse(&get_bytes(http, url(base, lat, lon)?).await?)
}

/// Splits the multi-model response into one [`SourceData`] per model. A model
/// missing from the response yields no entry.
pub fn parse(body: &[u8]) -> Result<Vec<SourceData>, SourceError> {
    let body: Body = serde_json::from_slice(body).map_err(|e| SourceError::Parse(e.to_string()))?;
    let hour_times = times(&body.hourly)?;
    let day_times = times(&body.daily)?;
    let day_tz = TimeZone::fixed(
        Offset::from_seconds(body.utc_offset_seconds)
            .map_err(|e| SourceError::Parse(format!("utc_offset_seconds: {e}")))?,
    );
    let mut out = Vec::new();
    for &(source, model) in MODELS {
        let h = |name: &str, i: usize| -> Option<f64> {
            body.hourly
                .get(&format!("{name}_{model}"))?
                .get(i)
                .copied()?
        };
        let d = |name: &str, i: usize| -> Option<f64> {
            body.daily
                .get(&format!("{name}_{model}"))?
                .get(i)
                .copied()?
        };
        if !body.hourly.contains_key(&format!("temperature_2m_{model}")) {
            continue;
        }

        let mut hourly = Vec::new();
        // Sums of hour i..i+1 sit at index i + 1.
        for (i, &at) in hour_times.iter().enumerate() {
            let (Some(temp_c), Some(wind_kmh), Some(precip_mm), Some(code)) = (
                h("temperature_2m", i),
                h("wind_speed_10m", i),
                h("precipitation", i + 1),
                h("weather_code", i + 1),
            ) else {
                continue;
            };
            let Some(condition) = wmo_condition(code, precip_mm) else {
                continue;
            };
            hourly.push(HourPoint {
                at,
                temp_c,
                feels_like_c: h("apparent_temperature", i),
                precip_mm,
                precip_prob_pct: h("precipitation_probability", i + 1),
                wind_kmh,
                gust_kmh: h("wind_gusts_10m", i),
                wind_dir_deg: h("wind_direction_10m", i),
                cloud_pct: h("cloud_cover", i),
                humidity_pct: h("relative_humidity_2m", i),
                pressure_hpa: h("pressure_msl", i),
                condition,
                is_day: h("is_day", i).map(|v| v >= 0.5),
            });
        }

        let mut daily = Vec::new();
        for (i, &start) in day_times.iter().enumerate() {
            let (Some(max), Some(min), Some(precip_mm), Some(wind), Some(code)) = (
                d("temperature_2m_max", i),
                d("temperature_2m_min", i),
                d("precipitation_sum", i),
                d("wind_speed_10m_max", i),
                d("weather_code", i),
            ) else {
                continue;
            };
            // Daily sums have no hourly intensity; treat a code-65 day as
            // heavy rain via the code alone.
            let Some(condition) = wmo_condition(code, 0.0) else {
                continue;
            };
            daily.push(DayPoint {
                date: start.to_zoned(day_tz.clone()).date(),
                temp_min_c: min,
                temp_max_c: max,
                precip_mm,
                precip_prob_pct: d("precipitation_probability_max", i),
                wind_max_kmh: wind,
                gust_max_kmh: d("wind_gusts_10m_max", i),
                condition,
                sunrise: d("sunrise", i).and_then(unix),
                sunset: d("sunset", i).and_then(unix),
            });
        }
        out.push(SourceData {
            source,
            hourly,
            daily,
        });
    }
    Ok(out)
}

fn unix(secs: f64) -> Option<Timestamp> {
    Timestamp::from_second(secs as i64).ok()
}

fn times(block: &HashMap<String, Vec<Option<f64>>>) -> Result<Vec<Timestamp>, SourceError> {
    block
        .get("time")
        .ok_or_else(|| SourceError::Parse("Feld time fehlt".into()))?
        .iter()
        .map(|t| {
            t.and_then(unix)
                .ok_or_else(|| SourceError::Parse("ungültige Zeit".into()))
        })
        .collect()
}

/// WMO weather interpretation codes (Open-Meteo docs, “WMO Weather
/// interpretation codes”). Unknown codes yield `None`.
pub fn wmo_condition(code: f64, precip_mm_h: f64) -> Option<Condition> {
    use Condition::*;
    let rain = if precip_mm_h >= HEAVY_RAIN_MM_H {
        HeavyRain
    } else {
        Rain
    };
    Some(match code as u16 {
        0 | 1 => Clear,
        2 => PartlyCloudy,
        3 => Cloudy,
        45 | 48 => Fog,
        51 | 53 | 55 => Drizzle,
        // Freezing drizzle and rain.
        56 | 57 | 66 | 67 => Sleet,
        61 | 63 | 80 | 81 => rain,
        65 | 82 => HeavyRain,
        71 | 73 | 75 | 77 | 85 | 86 => Snow,
        95 | 96 | 99 => Thunderstorm,
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use jiff::civil::date;

    const FIXTURE: &[u8] = include_bytes!("../../tests/fixtures/open_meteo/uelzen.json");
    const DST: &[u8] = include_bytes!("../../tests/fixtures/open_meteo/dst_end.json");

    fn by(data: &[SourceData], id: SourceId) -> &SourceData {
        data.iter().find(|d| d.source == id).unwrap()
    }

    #[test]
    fn splits_models_and_shifts_sums_to_hour_start() {
        let data = parse(FIXTURE).unwrap();
        assert_eq!(data.len(), 4);
        let ecmwf = by(&data, SourceId::EcmwfIfs);
        let first = &ecmwf.hourly[0];
        // Fixture hour 0 is 2026-11-09 00:00 Europe/Berlin = 23:00 UTC.
        assert_eq!(first.at.to_string(), "2026-11-08T23:00:00Z");
        assert_eq!(first.temp_c, 3.0);
        // The weather code at index 1 (00–01 local) belongs to hour 0.
        assert_eq!(first.condition, Condition::Cloudy);
        assert_eq!(ecmwf.hourly[1].condition, Condition::PartlyCloudy);
        assert_eq!(first.is_day, Some(false));
        // 8 hours of input give 7 points: the last hour has no sum.
        assert_eq!(ecmwf.hourly.len(), 7);
    }

    #[test]
    fn nulls_beyond_the_horizon_are_dropped_not_zeroed() {
        let data = parse(FIXTURE).unwrap();
        let d2 = by(&data, SourceId::IconD2);
        // ICON-D2 has values for hours 0..=5 only, so the last valid point
        // is hour 4 (it needs the sum at index 5).
        assert_eq!(d2.hourly.len(), 5);
        // Day 2 is null for ICON-D2 and must not appear.
        assert_eq!(d2.daily.len(), 1);
        assert_eq!(by(&data, SourceId::Gfs).daily.len(), 2);
    }

    #[test]
    fn daily_dates_use_the_response_offset_across_dst_end() {
        // 2026-10-25 is the last Sunday of October. Real response, requested
        // in CET (+01:00): the CEST days start at 01:00 local.
        let dates = |body: &[u8]| -> Vec<_> {
            by(&parse(body).unwrap(), SourceId::EcmwfIfs)
                .daily
                .iter()
                .map(|d| d.date)
                .collect()
        };
        let expected = [date(2026, 10, 24), date(2026, 10, 25), date(2026, 10, 26)];
        assert_eq!(dates(DST), expected);
        // Same days requested in CEST (+02:00): every midnight 1 h earlier.
        // Converting with tz rules would turn the 26th into the 25th.
        let mut summer: serde_json::Value = serde_json::from_slice(DST).unwrap();
        summer["utc_offset_seconds"] = 7200.into();
        for t in summer["daily"]["time"].as_array_mut().unwrap() {
            *t = (t.as_i64().unwrap() - 3600).into();
        }
        assert_eq!(dates(&serde_json::to_vec(&summer).unwrap()), expected);
    }

    #[test]
    fn wmo_codes() {
        assert_eq!(wmo_condition(63.0, 1.0), Some(Condition::Rain));
        assert_eq!(wmo_condition(63.0, 9.0), Some(Condition::HeavyRain));
        assert_eq!(wmo_condition(96.0, 0.0), Some(Condition::Thunderstorm));
        assert_eq!(wmo_condition(4.0, 0.0), None);
    }

    #[test]
    fn broken_json_is_a_parse_error() {
        assert!(matches!(parse(b"{}"), Err(SourceError::Parse(_))));
        assert!(matches!(parse(b"<html>"), Err(SourceError::Parse(_))));
    }
}
