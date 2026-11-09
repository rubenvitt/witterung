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
use crate::sources::{bright_sky, open_meteo, SourceData, SourceError};

const TICK: Duration = Duration::from_secs(60);
const BACKOFF_BASE: SignedDuration = SignedDuration::from_secs(60);

/// One upstream request type; quota is booked per provider.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Provider {
    OpenMeteo,
    BrightSky,
}

/// Attribution the licenses require, shown wherever the data is.
#[derive(Debug, Clone, Copy, Serialize)]
pub struct Attribution {
    pub text: &'static str,
    pub url: &'static str,
}

impl Provider {
    pub const ALL: [Provider; 2] = [Provider::OpenMeteo, Provider::BrightSky];

    pub fn name(self) -> &'static str {
        match self {
            Provider::OpenMeteo => "open_meteo",
            Provider::BrightSky => "bright_sky",
        }
    }

    pub fn interval(self) -> SignedDuration {
        match self {
            Provider::OpenMeteo | Provider::BrightSky => SignedDuration::from_hours(1),
        }
    }

    /// See docs/plan.md §4 for the numbers.
    pub fn budget(self) -> Budget {
        match self {
            Provider::OpenMeteo => Budget {
                quota: 10_000.0,
                period: Period::Day,
            },
            // No official quota (fair use): our own cap.
            Provider::BrightSky => Budget {
                quota: 6_000.0,
                period: Period::Day,
            },
        }
    }

    /// Weighted calls per request.
    pub fn weight(self) -> f64 {
        match self {
            Provider::OpenMeteo => open_meteo::request_weight(),
            Provider::BrightSky => 1.0,
        }
    }

    pub fn attribution(self) -> Attribution {
        match self {
            Provider::OpenMeteo => Attribution {
                text: "Wetterdaten von Open-Meteo.com (CC BY 4.0)",
                url: "https://open-meteo.com/",
            },
            Provider::BrightSky => Attribution {
                text: "Quelle: Deutscher Wetterdienst (DWD), abgerufen über Bright Sky",
                url: "https://www.dwd.de/",
            },
        }
    }

    async fn fetch(
        self,
        app: &App,
        place: &Place,
        now: Timestamp,
    ) -> Result<Vec<SourceData>, SourceError> {
        let endpoints = &app.config().endpoints;
        match self {
            Provider::OpenMeteo => {
                open_meteo::fetch(app.http(), &endpoints.open_meteo, place.lat, place.lon).await
            }
            Provider::BrightSky => {
                bright_sky::fetch(app.http(), &endpoints.bright_sky, place.lat, place.lon, now)
                    .await
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

/// One round over all places and providers (sequential: a hanging
/// upstream delays the others by at most the HTTP timeout).
pub async fn poll_once(app: &App, now: Timestamp) {
    let places = match app.blocking(db::list_places).await {
        Ok(p) => p,
        Err(e) => {
            tracing::error!(error = %e, "poller: cannot list places");
            return;
        }
    };
    for place in &places {
        for provider in Provider::ALL {
            if let Err(e) = poll(app, place, provider, now).await {
                tracing::error!(error = %e, place = place.id, provider = provider.name(), "poller: bookkeeping failed");
            }
        }
    }
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
    let (budget, weight) = (provider.budget(), provider.weight());
    let booked = app
        .blocking(move |c| quota::try_spend(c, name, budget, weight, now))
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
            data.iter()
                .map(|d| Ok((d.source.as_str(), serde_json::to_string(d)?)))
                .collect::<anyhow::Result<Vec<_>>>()?
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

/// Data older than this is flagged `stale` (3 × the poll interval).
pub const STALE_AFTER: SignedDuration = SignedDuration::from_hours(3);

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
