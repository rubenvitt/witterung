//! Aggregation: the stored per-source series of a place become one forecast
//! (docs/api.md): consensus = median per value, spread, per-source values,
//! observation, nowcast, warnings, attribution.

use std::collections::BTreeMap;

use jiff::civil::Date;
use jiff::{SignedDuration, Timestamp, ToSpan};
use serde::Serialize;

use crate::db::{FetchState, Place};
use crate::poller::{Attribution, Provider, ALERTS_KEY, NOWCAST_KEY, OBSERVATION_KEY};
use crate::sources::dwd::{Alert, Nowcast, Observation};
use crate::sources::{berlin, Condition, DayPoint, HourPoint, SourceData};

pub const HOURS: i64 = 48;
pub const DAYS: i64 = 10;
/// Older forecast series are left out of the consensus entirely.
const DROP_AFTER: SignedDuration = SignedDuration::from_hours(12);
const OBSERVATION_MAX_AGE: SignedDuration = SignedDuration::from_hours(2);
const NOWCAST_MAX_AGE: SignedDuration = SignedDuration::from_mins(40);

#[derive(Debug, Serialize)]
pub struct Forecast {
    pub location: Place,
    pub generated_at: Timestamp,
    pub sources: Vec<SourceStatus>,
    pub now: Now,
    pub nowcast: Option<Nowcast>,
    pub hourly: Vec<Row<HourPoint, HourSpread>>,
    pub daily: Vec<Row<DayPoint, DaySpread>>,
    pub alerts: Vec<Alert>,
    pub attribution: Vec<Attribution>,
}

#[derive(Debug, Serialize)]
pub struct SourceStatus {
    pub source: String,
    pub provider: Provider,
    pub ok: bool,
    pub fetched_at: Option<Timestamp>,
    pub stale: bool,
    pub error: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct Now {
    pub observed: Option<Observation>,
    pub forecast: Option<HourPoint>,
}

#[derive(Debug, Serialize)]
pub struct Row<P, S> {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub at: Option<Timestamp>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub date: Option<Date>,
    pub n_sources: usize,
    pub consensus: P,
    pub spread: S,
    pub by_source: BTreeMap<String, P>,
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq)]
pub struct Range {
    pub min: f64,
    pub max: f64,
}

#[derive(Debug, Serialize)]
pub struct HourSpread {
    pub temp_c: Range,
    pub precip_mm: Range,
    pub wind_kmh: Range,
    pub precip_agreement_pct: f64,
}

#[derive(Debug, Serialize)]
pub struct DaySpread {
    pub temp_min_c: Range,
    pub temp_max_c: Range,
    pub precip_mm: Range,
    pub precip_agreement_pct: f64,
}

/// Which provider a snapshot key comes from.
pub fn provider_of(key: &str) -> Option<Provider> {
    Some(match key {
        k if k.starts_with("open_meteo:") => Provider::OpenMeteo,
        "bright_sky:mosmix" => Provider::BrightSky,
        "weatherkit" => Provider::WeatherKit,
        "pirate_weather" => Provider::PirateWeather,
        OBSERVATION_KEY => Provider::DwdObservation,
        ALERTS_KEY => Provider::DwdAlerts,
        NOWCAST_KEY => Provider::DwdRadar,
        _ => return None,
    })
}

fn median(mut v: Vec<f64>) -> Option<f64> {
    v.retain(|x| x.is_finite());
    if v.is_empty() {
        return None;
    }
    v.sort_by(f64::total_cmp);
    let m = v.len() / 2;
    let x = if v.len() % 2 == 1 {
        v[m]
    } else {
        (v[m - 1] + v[m]) / 2.0
    };
    Some((x * 10.0).round() / 10.0)
}

fn range(v: impl Iterator<Item = f64>) -> Range {
    let (min, max) = v.fold((f64::INFINITY, f64::NEG_INFINITY), |(a, b), x| {
        (a.min(x), b.max(x))
    });
    Range { min, max }
}

fn agreement(v: &[f64], threshold: f64) -> f64 {
    if v.is_empty() {
        return 0.0;
    }
    (v.iter().filter(|&&x| x >= threshold).count() as f64 * 100.0 / v.len() as f64).round()
}

fn opt_median<P>(points: &[&P], f: impl Fn(&P) -> Option<f64>) -> Option<f64> {
    median(points.iter().filter_map(|p| f(p)).collect())
}

/// Most frequent condition; ties go to the more severe one.
fn mode(conditions: impl Iterator<Item = Condition>) -> Condition {
    let mut counts: Vec<(Condition, usize)> = Vec::new();
    for c in conditions {
        match counts.iter_mut().find(|(k, _)| *k == c) {
            Some((_, n)) => *n += 1,
            None => counts.push((c, 1)),
        }
    }
    counts
        .into_iter()
        .max_by_key(|&(c, n)| (n, severity(c)))
        .map_or(Condition::Cloudy, |(c, _)| c)
}

fn severity(c: Condition) -> u8 {
    use Condition::*;
    match c {
        Clear => 0,
        PartlyCloudy => 1,
        Cloudy => 2,
        Wind => 3,
        Fog => 4,
        Drizzle => 5,
        Rain => 6,
        Sleet => 7,
        Snow => 8,
        HeavyRain => 9,
        Hail => 10,
        Thunderstorm => 11,
    }
}

pub fn consensus_hour(at: Timestamp, points: &[&HourPoint]) -> HourPoint {
    let day_votes = points.iter().filter_map(|p| p.is_day).collect::<Vec<_>>();
    HourPoint {
        at,
        temp_c: opt_median(points, |p| Some(p.temp_c)).unwrap_or(f64::NAN),
        feels_like_c: opt_median(points, |p| p.feels_like_c),
        precip_mm: opt_median(points, |p| Some(p.precip_mm)).unwrap_or(0.0),
        precip_prob_pct: opt_median(points, |p| p.precip_prob_pct),
        wind_kmh: opt_median(points, |p| Some(p.wind_kmh)).unwrap_or(0.0),
        gust_kmh: opt_median(points, |p| p.gust_kmh),
        wind_dir_deg: circular_mean(points.iter().filter_map(|p| p.wind_dir_deg)),
        cloud_pct: opt_median(points, |p| p.cloud_pct),
        humidity_pct: opt_median(points, |p| p.humidity_pct),
        pressure_hpa: opt_median(points, |p| p.pressure_hpa),
        condition: mode(points.iter().map(|p| p.condition)),
        is_day: (!day_votes.is_empty())
            .then(|| day_votes.iter().filter(|&&d| d).count() * 2 >= day_votes.len()),
    }
}

/// Wind directions average on the circle (350° and 10° give 0°, not 180°).
fn circular_mean(dirs: impl Iterator<Item = f64>) -> Option<f64> {
    let (mut x, mut y, mut n) = (0.0, 0.0, 0);
    for d in dirs {
        x += d.to_radians().cos();
        y += d.to_radians().sin();
        n += 1;
    }
    (n > 0).then(|| y.atan2(x).to_degrees().round().rem_euclid(360.0))
}

pub fn consensus_day(date: Date, points: &[&DayPoint]) -> DayPoint {
    let first = |f: fn(&DayPoint) -> Option<Timestamp>| points.iter().find_map(|p| f(p));
    DayPoint {
        date,
        temp_min_c: opt_median(points, |p| Some(p.temp_min_c)).unwrap_or(f64::NAN),
        temp_max_c: opt_median(points, |p| Some(p.temp_max_c)).unwrap_or(f64::NAN),
        precip_mm: opt_median(points, |p| Some(p.precip_mm)).unwrap_or(0.0),
        precip_prob_pct: opt_median(points, |p| p.precip_prob_pct),
        wind_max_kmh: opt_median(points, |p| p.wind_max_kmh),
        gust_max_kmh: opt_median(points, |p| p.gust_max_kmh),
        condition: mode(points.iter().map(|p| p.condition)),
        sunrise: first(|p| p.sunrise),
        sunset: first(|p| p.sunset),
    }
}

pub struct Snapshot {
    pub key: String,
    pub fetched_at: i64,
    pub json: String,
}

/// Builds the forecast from stored snapshots and poll states.
pub fn build(
    place: Place,
    snapshots: Vec<Snapshot>,
    states: &[(Provider, FetchState)],
    configured: &[Provider],
    now: Timestamp,
) -> Forecast {
    let age = |fetched_at: i64| {
        Timestamp::from_millisecond(fetched_at)
            .map(|t| now.duration_since(t))
            .unwrap_or(SignedDuration::MAX)
    };
    let state_of = |p: Provider| states.iter().find(|(q, _)| *q == p).map(|(_, s)| s);

    let mut series: Vec<SourceData> = Vec::new();
    let mut sources = Vec::new();
    let (mut observed, mut nowcast, mut alerts) = (None, None, Vec::new());
    for snap in &snapshots {
        let Some(provider) = provider_of(&snap.key) else {
            continue;
        };
        let a = age(snap.fetched_at);
        match snap.key.as_str() {
            OBSERVATION_KEY => {
                observed = serde_json::from_str::<Observation>(&snap.json)
                    .ok()
                    .filter(|o| now.duration_since(o.at) <= OBSERVATION_MAX_AGE);
            }
            NOWCAST_KEY => {
                nowcast = serde_json::from_str::<Nowcast>(&snap.json)
                    .ok()
                    .filter(|_| a <= NOWCAST_MAX_AGE);
            }
            ALERTS_KEY => {
                alerts = serde_json::from_str::<Vec<Alert>>(&snap.json)
                    .unwrap_or_default()
                    .into_iter()
                    .filter(|al| al.expires.is_none_or(|e| e > now))
                    .collect();
            }
            _ => {
                let state = state_of(provider);
                sources.push(SourceStatus {
                    source: snap.key.clone(),
                    provider,
                    ok: state.is_none_or(|s| s.failures == 0 && s.error.is_none()),
                    fetched_at: Timestamp::from_millisecond(snap.fetched_at).ok(),
                    stale: a > provider.stale_after(),
                    error: state.and_then(|s| s.error.clone()),
                });
                if a <= DROP_AFTER {
                    if let Ok(data) = serde_json::from_str::<SourceData>(&snap.json) {
                        series.push(data);
                    }
                }
            }
        }
    }
    // Forecast providers that failed before ever delivering still show up.
    for &p in configured {
        let is_forecast = matches!(
            p,
            Provider::OpenMeteo
                | Provider::BrightSky
                | Provider::WeatherKit
                | Provider::PirateWeather
        );
        if is_forecast && !sources.iter().any(|s| s.provider == p) {
            if let Some(s) = state_of(p).filter(|s| s.error.is_some()) {
                sources.push(SourceStatus {
                    source: p.name().into(),
                    provider: p,
                    ok: false,
                    fetched_at: None,
                    stale: false,
                    error: s.error.clone(),
                });
            }
        }
    }

    let tz = berlin();
    let hour0 = Timestamp::from_second(now.as_second().div_euclid(3600) * 3600).unwrap_or(now);
    let mut hourly = Vec::new();
    for k in 0..HOURS {
        let at = hour0 + SignedDuration::from_hours(k);
        let by: Vec<(&str, &HourPoint)> = series
            .iter()
            .filter_map(|s| {
                s.hourly
                    .iter()
                    .find(|p| p.at == at)
                    .map(|p| (s.source.as_str(), p))
            })
            .collect();
        if by.is_empty() {
            continue;
        }
        let points: Vec<&HourPoint> = by.iter().map(|(_, p)| *p).collect();
        let precips: Vec<f64> = points.iter().map(|p| p.precip_mm).collect();
        hourly.push(Row {
            at: Some(at),
            date: None,
            n_sources: points.len(),
            consensus: consensus_hour(at, &points),
            spread: HourSpread {
                temp_c: range(points.iter().map(|p| p.temp_c)),
                precip_mm: range(precips.iter().copied()),
                wind_kmh: range(points.iter().map(|p| p.wind_kmh)),
                precip_agreement_pct: agreement(&precips, 0.1),
            },
            by_source: by
                .into_iter()
                .map(|(s, p)| (s.to_owned(), p.clone()))
                .collect(),
        });
    }

    let today = now.to_zoned(tz).date();
    let mut daily = Vec::new();
    for k in 0..DAYS {
        let Ok(date) = today.checked_add(k.days()) else {
            continue;
        };
        let by: Vec<(&str, &DayPoint)> = series
            .iter()
            .filter_map(|s| {
                s.daily
                    .iter()
                    .find(|d| d.date == date)
                    .map(|d| (s.source.as_str(), d))
            })
            .collect();
        if by.is_empty() {
            continue;
        }
        let points: Vec<&DayPoint> = by.iter().map(|(_, p)| *p).collect();
        let precips: Vec<f64> = points.iter().map(|p| p.precip_mm).collect();
        daily.push(Row {
            at: None,
            date: Some(date),
            n_sources: points.len(),
            consensus: consensus_day(date, &points),
            spread: DaySpread {
                temp_min_c: range(points.iter().map(|p| p.temp_min_c)),
                temp_max_c: range(points.iter().map(|p| p.temp_max_c)),
                precip_mm: range(precips.iter().copied()),
                precip_agreement_pct: agreement(&precips, 1.0),
            },
            by_source: by
                .into_iter()
                .map(|(s, p)| (s.to_owned(), p.clone()))
                .collect(),
        });
    }

    let mut attribution: Vec<Attribution> = Vec::new();
    for p in configured {
        let a = p.attribution();
        if !attribution.iter().any(|b| b.source == a.source) {
            attribution.push(a);
        }
    }
    sources.sort_by(|a, b| a.source.cmp(&b.source));

    Forecast {
        location: place,
        generated_at: now,
        sources,
        now: Now {
            observed,
            forecast: hourly.first().map(|r| r.consensus.clone()),
        },
        nowcast,
        hourly,
        daily,
        alerts,
        attribution,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hp(at: Timestamp, temp: f64, precip: f64, c: Condition) -> HourPoint {
        HourPoint {
            at,
            temp_c: temp,
            feels_like_c: None,
            precip_mm: precip,
            precip_prob_pct: None,
            wind_kmh: 10.0,
            gust_kmh: None,
            wind_dir_deg: None,
            cloud_pct: None,
            humidity_pct: None,
            pressure_hpa: None,
            condition: c,
            is_day: Some(true),
        }
    }

    #[test]
    fn median_resists_an_outlier() {
        assert_eq!(median(vec![5.0, 5.2, 4.9, 20.0]), Some(5.1));
        assert_eq!(median(vec![1.0, 2.0, 30.0]), Some(2.0));
        assert_eq!(median(vec![]), None);
    }

    #[test]
    fn ties_go_to_the_more_severe_condition() {
        use Condition::*;
        assert_eq!(mode([Cloudy, Rain, Rain, Cloudy].into_iter()), Rain);
        assert_eq!(mode([Clear, Clear, Rain].into_iter()), Clear);
    }

    #[test]
    fn wind_direction_wraps() {
        assert_eq!(circular_mean([350.0, 10.0].into_iter()), Some(0.0));
        assert_eq!(circular_mean([80.0, 100.0].into_iter()), Some(90.0));
    }

    fn snap(key: &str, at: Timestamp, data: &impl Serialize) -> Snapshot {
        Snapshot {
            key: key.into(),
            fetched_at: at.as_millisecond(),
            json: serde_json::to_string(data).unwrap(),
        }
    }

    #[test]
    fn rows_count_only_sources_with_values() {
        let now: Timestamp = "2026-11-09T12:20:00Z".parse().unwrap();
        let h0: Timestamp = "2026-11-09T12:00:00Z".parse().unwrap();
        let h1 = h0 + SignedDuration::from_hours(1);
        let a = SourceData {
            source: crate::sources::SourceId::IconD2,
            hourly: vec![
                hp(h0, 5.0, 0.0, Condition::Cloudy),
                hp(h1, 6.0, 0.4, Condition::Rain),
            ],
            daily: vec![],
        };
        let b = SourceData {
            source: crate::sources::SourceId::Gfs,
            hourly: vec![hp(h0, 7.0, 0.0, Condition::Cloudy)],
            daily: vec![],
        };
        let place = Place {
            id: 1,
            name: "Test".into(),
            lat: 52.97,
            lon: 10.56,
            kind: "saved".into(),
            notify: false,
            last_requested_at: None,
        };
        let f = build(
            place,
            vec![
                snap("open_meteo:icon_d2", now, &a),
                snap("open_meteo:gfs", now, &b),
            ],
            &[],
            &[Provider::OpenMeteo, Provider::BrightSky],
            now,
        );
        assert_eq!(f.hourly.len(), 2);
        assert_eq!(f.hourly[0].n_sources, 2);
        assert_eq!(f.hourly[0].consensus.temp_c, 6.0);
        assert_eq!(f.hourly[0].spread.temp_c, Range { min: 5.0, max: 7.0 });
        assert_eq!(f.hourly[1].n_sources, 1);
        assert_eq!(f.hourly[1].spread.precip_agreement_pct, 100.0);
        assert_eq!(f.now.forecast.as_ref().unwrap().temp_c, 6.0);
        assert_eq!(f.sources.len(), 2);
        // Open-Meteo and DWD, each once.
        assert_eq!(f.attribution.len(), 2);

        // A day later the series are too old for the consensus.
        let later = now + SignedDuration::from_hours(13);
        let f = build(
            f.location,
            vec![snap("open_meteo:icon_d2", now, &a)],
            &[],
            &[Provider::OpenMeteo],
            later,
        );
        assert!(f.hourly.is_empty());
        assert!(f.sources[0].stale);
    }
}
