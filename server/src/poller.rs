//! Background polling: every minute, fetch each due provider for each place,
//! book its quota first, store the normalized result. A failing provider
//! only marks its own state; the others go on.
//!
//! Due times derive from `fetch_state` in SQLite, so a restart (every
//! deploy) does not refetch. After an error: backoff 1, 2, 4 … min, capped
//! at the regular interval.

use std::time::Duration;

use jiff::{SignedDuration, Timestamp};
use serde::Serialize;

use crate::app::App;
use crate::db::{self, FetchState, Place};
use crate::quota::{self, Budget, Period};
use crate::sources::{
    bright_sky, dwd, open_meteo, pirate_weather, weatherkit, SourceData, SourceError,
};

const TICK: Duration = Duration::from_secs(60);
const BACKOFF_BASE: SignedDuration = SignedDuration::from_secs(60);

/// One upstream request type; state per (place, provider), quota per
/// [`Provider::quota_key`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Provider {
    OpenMeteo,
    BrightSky,
    #[serde(rename = "weatherkit")]
    WeatherKit,
    PirateWeather,
    /// Bright Sky `/current_weather` (DWD station observation).
    DwdObservation,
    /// Bright Sky `/alerts`.
    DwdAlerts,
    /// Bright Sky `/radar` (nowcast).
    DwdRadar,
}

/// Attribution the licenses require, shown wherever the data is.
#[derive(Debug, Clone, Copy, Serialize)]
pub struct Attribution {
    pub source: &'static str,
    pub text: &'static str,
    pub url: &'static str,
}

/// Snapshot keys of the non-forecast feeds.
pub const OBSERVATION_KEY: &str = "dwd:observation";
pub const ALERTS_KEY: &str = "dwd:alerts";
pub const NOWCAST_KEY: &str = "dwd:nowcast";

impl Provider {
    pub const ALL: [Provider; 7] = [
        Provider::OpenMeteo,
        Provider::BrightSky,
        Provider::WeatherKit,
        Provider::PirateWeather,
        Provider::DwdObservation,
        Provider::DwdAlerts,
        Provider::DwdRadar,
    ];

    /// Sources with credentials are off until the credentials are set.
    pub fn configured(self, config: &crate::Config) -> bool {
        match self {
            Provider::WeatherKit => config.weatherkit.is_some(),
            Provider::PirateWeather => config.pirate_weather_key.is_some(),
            _ => true,
        }
    }

    /// Whether this provider is polled for a place. Pirate Weather (tight
    /// monthly quota) only for saved places.
    pub fn applies_to(self, place: &Place) -> bool {
        !(self == Provider::PirateWeather && place.kind != "saved")
    }

    pub fn name(self) -> &'static str {
        match self {
            Provider::OpenMeteo => "open_meteo",
            Provider::BrightSky => "bright_sky",
            Provider::WeatherKit => "weatherkit",
            Provider::PirateWeather => "pirate_weather",
            Provider::DwdObservation => "dwd_observation",
            Provider::DwdAlerts => "dwd_alerts",
            Provider::DwdRadar => "dwd_radar",
        }
    }

    /// The account whose quota a call uses.
    pub fn quota_key(self) -> &'static str {
        match self {
            Provider::BrightSky
            | Provider::DwdObservation
            | Provider::DwdAlerts
            | Provider::DwdRadar => "bright_sky",
            p => p.name(),
        }
    }

    pub fn interval(self) -> SignedDuration {
        match self {
            Provider::WeatherKit | Provider::DwdObservation => SignedDuration::from_mins(15),
            Provider::DwdAlerts | Provider::DwdRadar => SignedDuration::from_mins(10),
            Provider::OpenMeteo | Provider::BrightSky | Provider::PirateWeather => {
                SignedDuration::from_hours(1)
            }
        }
    }

    /// Older data is flagged `stale` (3 × the interval).
    pub fn stale_after(self) -> SignedDuration {
        self.interval() * 3
    }

    /// See docs/schema.md for the numbers.
    pub fn budget(self) -> Budget {
        match self.quota_key() {
            "open_meteo" => Budget {
                quota: 10_000.0,
                period: Period::Day,
            },
            "weatherkit" => Budget {
                quota: 500_000.0,
                period: Period::Month,
            },
            "pirate_weather" => Budget {
                quota: 10_000.0,
                period: Period::Month,
            },
            // Bright Sky has no official quota (fair use): our own cap.
            _ => Budget {
                quota: 6_000.0,
                period: Period::Day,
            },
        }
    }

    /// Weighted calls per request.
    pub fn weight(self) -> f64 {
        match self {
            Provider::OpenMeteo => open_meteo::request_weight(),
            _ => 1.0,
        }
    }

    pub fn attribution(self) -> Attribution {
        match self {
            Provider::OpenMeteo => Attribution {
                source: "open_meteo",
                text: "Wetterdaten von Open-Meteo.com (CC BY 4.0)",
                url: "https://open-meteo.com/",
            },
            Provider::WeatherKit => Attribution {
                source: "weatherkit",
                text: "Apple Weather",
                url: "https://developer.apple.com/weatherkit/data-source-attribution/",
            },
            Provider::PirateWeather => Attribution {
                source: "pirate_weather",
                text: "Pirate Weather",
                url: "https://pirateweather.net/",
            },
            _ => Attribution {
                source: "dwd",
                text: "Quelle: Deutscher Wetterdienst (DWD), abgerufen über Bright Sky",
                url: "https://www.dwd.de/",
            },
        }
    }

    /// `(snapshot key, JSON)` pairs.
    async fn fetch(
        self,
        app: &App,
        place: &Place,
        now: Timestamp,
    ) -> Result<Vec<(String, String)>, SourceError> {
        let config = app.config();
        let e = &config.endpoints;
        let (http, lat, lon) = (app.http(), place.lat, place.lon);
        let forecast = |data: Vec<SourceData>| -> Result<Vec<(String, String)>, SourceError> {
            data.iter()
                .map(|d| {
                    serde_json::to_string(d)
                        .map(|j| (d.source.as_str().to_owned(), j))
                        .map_err(|e| SourceError::Parse(e.to_string()))
                })
                .collect()
        };
        let one = |key: &str, v: Result<String, serde_json::Error>| {
            v.map(|j| vec![(key.to_owned(), j)])
                .map_err(|e| SourceError::Parse(e.to_string()))
        };
        match self {
            Provider::OpenMeteo => {
                forecast(open_meteo::fetch(http, &e.open_meteo, lat, lon).await?)
            }
            Provider::BrightSky => {
                forecast(bright_sky::fetch(http, &e.bright_sky, lat, lon, now).await?)
            }
            Provider::WeatherKit => {
                let Some(wk) = &config.weatherkit else {
                    return Err(SourceError::Http("nicht konfiguriert".into()));
                };
                forecast(weatherkit::fetch(http, &e.weatherkit, wk, lat, lon, now).await?)
            }
            Provider::PirateWeather => {
                let Some(key) = &config.pirate_weather_key else {
                    return Err(SourceError::Http("nicht konfiguriert".into()));
                };
                forecast(pirate_weather::fetch(http, &e.pirate_weather, &key.0, lat, lon).await?)
            }
            Provider::DwdObservation => {
                let o = dwd::fetch_observation(http, &e.bright_sky, lat, lon).await?;
                one(OBSERVATION_KEY, serde_json::to_string(&o))
            }
            Provider::DwdAlerts => {
                let a = dwd::fetch_alerts(http, &e.bright_sky, lat, lon).await?;
                one(ALERTS_KEY, serde_json::to_string(&a))
            }
            Provider::DwdRadar => {
                let n = dwd::fetch_nowcast(http, &e.bright_sky, lat, lon, now).await?;
                one(NOWCAST_KEY, serde_json::to_string(&n))
            }
        }
    }
}

pub fn is_due(state: &FetchState, interval: SignedDuration, now: Timestamp) -> bool {
    let Some(last) = state
        .last_attempt_at
        .and_then(|ms| Timestamp::from_millisecond(ms).ok())
    else {
        return true;
    };
    let wait = if state.failures == 0 {
        interval
    } else {
        let factor = 1i32 << state.failures.saturating_sub(1).min(16);
        (BACKOFF_BASE * factor).min(interval)
    };
    now.duration_since(last) >= wait
}

/// Runs forever; started once by `run`.
pub fn spawn(app: App) {
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(TICK);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            tick.tick().await;
            poll_once(&app, Timestamp::now()).await;
        }
    });
}

/// Current-location places are polled while requested within this window.
pub const CURRENT_ACTIVE: SignedDuration = SignedDuration::from_hours(24);

/// One round over all places and providers (sequential: a hanging
/// upstream delays the others by at most the HTTP timeout), then push
/// checks and housekeeping.
pub async fn poll_once(app: &App, now: Timestamp) {
    let places = match app.blocking(db::list_places).await {
        Ok(p) => p,
        Err(e) => {
            tracing::error!(error = %e, "poller: cannot list places");
            return;
        }
    };
    let active_since = (now - CURRENT_ACTIVE).as_millisecond();
    for place in places
        .iter()
        .filter(|p| p.kind == "saved" || p.last_requested_at.unwrap_or(0) >= active_since)
    {
        poll_place(app, place, &Provider::ALL, now).await;
    }
    if let Err(e) = crate::push::evaluate(app, now).await {
        tracing::error!(error = %e, "push check failed");
    }
    if let Err(e) = housekeeping(app, now).await {
        tracing::error!(error = %e, "housekeeping failed");
    }
}

/// Polls the given providers for one place where due and configured.
pub async fn poll_place(app: &App, place: &Place, providers: &[Provider], now: Timestamp) {
    for &provider in providers {
        if !provider.configured(app.config()) || !provider.applies_to(place) {
            continue;
        }
        if let Err(e) = poll(app, place, provider, now).await {
            tracing::error!(error = %e, place = place.id, provider = provider.name(), "poller: bookkeeping failed");
        }
    }
}

async fn housekeeping(app: &App, now: Timestamp) -> crate::error::AppResult<()> {
    let week_ago = (now - SignedDuration::from_hours(24 * 7)).as_millisecond();
    app.blocking(move |c| {
        db::purge_current_places(c, week_ago)?;
        db::purge_push_sent(c, week_ago)
    })
    .await?;
    crate::backup::maybe_run(app, now).await
}

async fn poll(
    app: &App,
    place: &Place,
    provider: Provider,
    now: Timestamp,
) -> crate::error::AppResult<()> {
    let (id, name) = (place.id, provider.name());
    let state = app.blocking(move |c| db::fetch_state(c, id, name)).await?;
    if !is_due(&state, provider.interval(), now) {
        return Ok(());
    }
    let (budget, weight, account) = (provider.budget(), provider.weight(), provider.quota_key());
    let booked = app
        .blocking(move |c| quota::try_spend(c, account, budget, weight, now))
        .await?;
    if !booked {
        // No attempt is recorded: it stays due and is retried next tick
        // (cheap, no upstream call) until the period rolls over.
        if state.error.as_deref() != Some(QUOTA_ERROR) {
            tracing::warn!(provider = name, "quota limit reached, serving last data");
            let state = FetchState {
                error: Some(QUOTA_ERROR.into()),
                ..state
            };
            app.blocking(move |c| db::save_fetch_state(c, id, name, &state))
                .await?;
        }
        return Ok(());
    }

    let result = provider.fetch(app, place, now).await;
    let at = now.as_millisecond();
    let mut state = FetchState {
        last_attempt_at: Some(at),
        ..state
    };
    let snapshots = match result {
        Ok(data) => {
            state.last_success_at = Some(at);
            state.failures = 0;
            state.error = None;
            data
        }
        Err(e) => {
            tracing::warn!(provider = name, place = id, error = %e, "fetch failed");
            state.failures += 1;
            state.error = Some(e.to_string());
            Vec::new()
        }
    };
    app.blocking(move |c| {
        let tx = c.unchecked_transaction()?;
        for (source, json) in &snapshots {
            db::save_snapshot(&tx, id, source, at, json)?;
        }
        db::save_fetch_state(&tx, id, name, &state)?;
        tx.commit()?;
        Ok(())
    })
    .await
}

pub const QUOTA_ERROR: &str = "quota";

#[cfg(test)]
mod tests {
    use super::*;

    fn state(attempt_min_ago: i64, failures: u32, now: Timestamp) -> FetchState {
        FetchState {
            last_attempt_at: Some(now.as_millisecond() - attempt_min_ago * 60_000),
            failures,
            ..Default::default()
        }
    }

    #[test]
    fn due_after_interval_and_backoff_capped() {
        let now: Timestamp = "2026-11-09T12:00:00Z".parse().unwrap();
        let hour = SignedDuration::from_hours(1);
        assert!(is_due(&FetchState::default(), hour, now), "never fetched");
        assert!(!is_due(&state(59, 0, now), hour, now));
        assert!(is_due(&state(60, 0, now), hour, now));
        // Backoff: 1, 2, 4 min …
        assert!(is_due(&state(1, 1, now), hour, now));
        assert!(!is_due(&state(1, 2, now), hour, now));
        assert!(is_due(&state(2, 2, now), hour, now));
        // … but never longer than the interval.
        assert!(is_due(&state(60, 30, now), hour, now));
    }
}
