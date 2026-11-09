//! Upstream quotas. Every call is booked BEFORE it is made (failed calls
//! count too); a call that would cross the limit is not made. The limit is
//! half the upstream's quota (hard rule: stay below 50 %). Periods are UTC.

use jiff::Timestamp;
use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Period {
    Day,
    Month,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct Budget {
    /// The upstream's quota (or our own cap where there is none).
    pub quota: f64,
    pub period: Period,
}

impl Budget {
    /// What we allow ourselves: 50 % of the quota.
    pub fn limit(&self) -> f64 {
        self.quota / 2.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct Usage {
    pub used: f64,
    pub limit: f64,
    pub period: Period,
}

fn period_key(period: Period, now: Timestamp) -> String {
    let fmt = match period {
        Period::Day => "%Y-%m-%d",
        Period::Month => "%Y-%m",
    };
    now.strftime(fmt).to_string()
}

fn used(conn: &Connection, provider: &str, key: &str) -> anyhow::Result<f64> {
    Ok(conn
        .query_row(
            "SELECT used FROM quota_usage WHERE provider = ?1 AND period = ?2",
            params![provider, key],
            |r| r.get(0),
        )
        .optional()?
        .unwrap_or(0.0))
}

/// Books `weight` calls if they fit under the limit; `false` = not booked,
/// do not call.
pub fn try_spend(
    conn: &Connection,
    provider: &str,
    budget: Budget,
    weight: f64,
    now: Timestamp,
) -> anyhow::Result<bool> {
    let key = period_key(budget.period, now);
    // Single connection behind a mutex: read and write cannot interleave.
    if used(conn, provider, &key)? + weight > budget.limit() {
        return Ok(false);
    }
    conn.execute(
        "INSERT INTO quota_usage (provider, period, used) VALUES (?1, ?2, ?3)
         ON CONFLICT (provider, period) DO UPDATE SET used = used + excluded.used",
        params![provider, key, weight],
    )?;
    Ok(true)
}

pub fn usage(
    conn: &Connection,
    provider: &str,
    budget: Budget,
    now: Timestamp,
) -> anyhow::Result<Usage> {
    Ok(Usage {
        used: used(conn, provider, &period_key(budget.period, now))?,
        limit: budget.limit(),
        period: budget.period,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stops_at_half_the_quota_and_resets_per_period() {
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::db::open(&dir.path().join("q.db")).unwrap();
        let budget = Budget {
            quota: 10.0,
            period: Period::Day,
        };
        let day1: Timestamp = "2026-11-09T23:59:00Z".parse().unwrap();
        let day2: Timestamp = "2026-11-10T00:00:00Z".parse().unwrap();
        assert!(try_spend(&conn, "x", budget, 3.0, day1).unwrap());
        assert!(try_spend(&conn, "x", budget, 2.0, day1).unwrap());
        assert!(
            !try_spend(&conn, "x", budget, 0.5, day1).unwrap(),
            "5 of 5 used"
        );
        assert_eq!(usage(&conn, "x", budget, day1).unwrap().used, 5.0);
        assert!(try_spend(&conn, "x", budget, 1.0, day2).unwrap());
        assert!(try_spend(&conn, "other", budget, 5.0, day1).unwrap());
    }

    #[test]
    fn month_keys() {
        let t: Timestamp = "2026-11-30T23:00:00Z".parse().unwrap();
        assert_eq!(period_key(Period::Month, t), "2026-11");
        assert_eq!(period_key(Period::Day, t), "2026-11-30");
    }
}
