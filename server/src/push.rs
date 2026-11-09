//! Push via ntfy: new DWD warning (from `moderate`) and rain starting within
//! 30 minutes (radar nowcast), for places with `notify`. Settings live in the
//! database (`settings.notifications`), edited through the API.

use axum::extract::State;
use axum::Json;
use jiff::{SignedDuration, Timestamp};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use url::Url;

use crate::app::{now_ms, App};
use crate::db;
use crate::error::{AppError, AppResult};
use crate::poller::{ALERTS_KEY, NOWCAST_KEY};
use crate::sources::dwd::{Alert, Nowcast};

const SETTINGS_KEY: &str = "notifications";
/// Rain counts from this intensity (mm/h).
const RAIN_MM_H: f64 = 0.2;
const RAIN_LEAD: SignedDuration = SignedDuration::from_mins(30);

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Settings {
    pub ntfy_url: Option<String>,
    pub topic: Option<String>,
    pub token: Option<String>,
    pub enabled: bool,
}

async fn load(app: &App) -> AppResult<Settings> {
    let raw = app.blocking(|c| db::get_setting(c, SETTINGS_KEY)).await?;
    Ok(raw
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default())
}

fn public(s: &Settings) -> Value {
    json!({
        "ntfy_url": s.ntfy_url,
        "topic": s.topic,
        "enabled": s.enabled,
        "token_set": s.token.is_some(),
    })
}

pub async fn get_settings(State(app): State<App>) -> AppResult<Json<Value>> {
    Ok(Json(public(&load(&app).await?)))
}

#[derive(Deserialize)]
pub struct SettingsUpdate {
    ntfy_url: Option<String>,
    topic: Option<String>,
    /// `""` removes the token; absent keeps it.
    token: Option<String>,
    enabled: Option<bool>,
}

pub async fn put_settings(
    State(app): State<App>,
    Json(u): Json<SettingsUpdate>,
) -> AppResult<Json<Value>> {
    let mut s = load(&app).await?;
    if let Some(url) = u.ntfy_url {
        let url = url.trim().trim_end_matches('/').to_owned();
        if !url.is_empty() {
            let parsed = Url::parse(&url)
                .map_err(|_| AppError::BadRequest("ntfy_url ist keine URL".into()))?;
            if !matches!(parsed.scheme(), "https" | "http") {
                return Err(AppError::BadRequest("ntfy_url muss http(s) sein".into()));
            }
        }
        let url = Some(url).filter(|u| !u.is_empty());
        // A token never follows a changed address unless given again: else a
        // stolen login could redirect the token to a server of its choosing.
        if url != s.ntfy_url && u.token.is_none() {
            s.token = None;
        }
        s.ntfy_url = url;
    }
    if let Some(topic) = u.topic {
        let topic = topic.trim().to_owned();
        if topic.len() > 64
            || !topic
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
        {
            return Err(AppError::BadRequest(
                "topic: nur Buchstaben, Ziffern, - und _ (höchstens 64)".into(),
            ));
        }
        s.topic = Some(topic).filter(|t| !t.is_empty());
    }
    if let Some(token) = u.token {
        s.token = Some(token.trim().to_owned()).filter(|t| !t.is_empty());
    }
    if let Some(enabled) = u.enabled {
        s.enabled = enabled;
    }
    let json = serde_json::to_string(&s).map_err(|e| AppError::Internal(e.into()))?;
    app.blocking(move |c| db::set_setting(c, SETTINGS_KEY, &json))
        .await?;
    Ok(Json(public(&s)))
}

pub async fn test(State(app): State<App>) -> AppResult<Json<Value>> {
    let s = load(&app).await?;
    send(
        &app,
        &s,
        Message {
            title: "Witterung".into(),
            message: "Testnachricht: Benachrichtigungen kommen an.".into(),
            priority: 3,
            tags: vec!["white_check_mark".into()],
        },
    )
    .await
    .map_err(AppError::BadRequest)?;
    Ok(Json(json!({"sent": true})))
}

#[derive(Debug)]
pub struct Message {
    pub title: String,
    pub message: String,
    pub priority: u8,
    pub tags: Vec<String>,
}

async fn send(app: &App, s: &Settings, m: Message) -> Result<(), String> {
    let (Some(url), Some(topic)) = (&s.ntfy_url, &s.topic) else {
        return Err("ntfy-Adresse und Topic fehlen".into());
    };
    let mut req = app.http().post(url).json(&json!({
        "topic": topic,
        "title": m.title,
        "message": m.message,
        "priority": m.priority,
        "tags": m.tags,
    }));
    if let Some(token) = &s.token {
        req = req.bearer_auth(token);
    }
    let r = req
        .send()
        .await
        .map_err(|e| format!("ntfy nicht erreichbar: {}", e.without_url()))?;
    if !r.status().is_success() {
        return Err(format!("ntfy antwortet {}", r.status()));
    }
    Ok(())
}

fn german(v: f64) -> String {
    format!("{v:.1}").replace('.', ",")
}

/// What should be announced for a place, as `(dedupe key, message)`.
pub fn due_messages(
    place: &str,
    alerts: &[Alert],
    nowcast: Option<&Nowcast>,
    now: Timestamp,
) -> Vec<(String, Message)> {
    let mut out = Vec::new();
    for a in alerts.iter().filter(|a| a.severity_rank() >= 2) {
        let until = a
            .expires
            .map(|e| format!(" bis {}", crate::sources::berlin_time(e)))
            .unwrap_or_default();
        out.push((
            format!("alert:{}", a.id),
            Message {
                title: format!("{place}: {}", a.headline),
                message: format!("{}{until}\n\n{}", a.event, a.description),
                priority: if a.severity_rank() >= 3 { 5 } else { 4 },
                tags: vec!["warning".into()],
            },
        ));
    }
    if let Some(n) = nowcast {
        let current = n
            .points
            .iter()
            .rfind(|p| p.at <= now)
            .map_or(0.0, |p| p.precip_mm_h);
        let start = n
            .points
            .iter()
            .find(|p| p.at > now && p.at <= now + RAIN_LEAD && p.precip_mm_h >= RAIN_MM_H);
        if let (true, Some(p)) = (current < RAIN_MM_H, start) {
            let mins = (p.at.duration_since(now).as_secs() + 59) / 60;
            let peak = n
                .points
                .iter()
                .filter(|q| q.at >= p.at)
                .map(|q| q.precip_mm_h)
                .fold(0.0, f64::max);
            let kind = if peak >= 7.6 {
                "Starkregen"
            } else if peak >= 2.5 {
                "Regen"
            } else {
                "leichter Regen"
            };
            // One message per rain onset: dedupe on the 2-hour window.
            let window = p.at.as_second().div_euclid(7200);
            out.push((
                format!("rain:{window}"),
                Message {
                    title: format!("{place}: Regen in {mins} min"),
                    message: format!(
                        "Ab {} {kind} (bis {} mm/h) laut Radar.",
                        crate::sources::berlin_time(p.at),
                        german(peak)
                    ),
                    priority: 3,
                    tags: vec!["umbrella".into()],
                },
            ));
        }
    }
    out
}

/// Runs after each poll round.
pub async fn evaluate(app: &App, now: Timestamp) -> AppResult<()> {
    let s = load(app).await?;
    if !s.enabled || s.ntfy_url.is_none() || s.topic.is_none() {
        return Ok(());
    }
    let places: Vec<_> = app
        .blocking(db::list_places)
        .await?
        .into_iter()
        .filter(|p| p.notify && p.kind == "saved")
        .collect();
    for place in places {
        let id = place.id;
        let snaps = app.blocking(move |c| db::snapshots(c, id)).await?;
        let get = |key: &str| {
            snaps
                .iter()
                .find(|(k, _, _)| k == key)
                .map(|(_, _, j)| j.as_str())
        };
        let alerts: Vec<Alert> = get(ALERTS_KEY)
            .and_then(|j| serde_json::from_str(j).ok())
            .unwrap_or_default();
        let nowcast: Option<Nowcast> = get(NOWCAST_KEY).and_then(|j| serde_json::from_str(j).ok());
        for (key, msg) in due_messages(&place.name, &alerts, nowcast.as_ref(), now) {
            let k = key.clone();
            let fresh = app
                .blocking(move |c| db::mark_push_sent(c, id, &k, now_ms()))
                .await?;
            if !fresh {
                continue;
            }
            if let Err(e) = send(app, &s, msg).await {
                tracing::warn!(error = %e, "push failed, retry next round");
                app.blocking(move |c| db::unmark_push_sent(c, id, &key))
                    .await?;
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sources::dwd::NowcastPoint;

    fn nowcast(start: Timestamp, values: &[f64]) -> Nowcast {
        Nowcast {
            source: "bright_sky:radar".into(),
            at: start,
            points: values
                .iter()
                .enumerate()
                .map(|(i, &v)| NowcastPoint {
                    at: start + SignedDuration::from_mins(5 * i as i64),
                    precip_mm_h: v,
                })
                .collect(),
        }
    }

    #[test]
    fn rain_soon_once_and_not_when_already_raining() {
        let t0: Timestamp = "2026-11-09T12:00:00Z".parse().unwrap();
        let now = t0 + SignedDuration::from_mins(2);
        let n = nowcast(t0, &[0.0, 0.0, 0.0, 0.0, 1.2, 3.0, 0.5]);
        let m = due_messages("Uelzen", &[], Some(&n), now);
        assert_eq!(m.len(), 1);
        assert_eq!(m[0].1.title, "Uelzen: Regen in 18 min");
        assert!(m[0].1.message.contains("13:20"), "{}", m[0].1.message);
        assert!(m[0].1.message.contains("3,0 mm/h"));
        // Already raining: no message.
        let n = nowcast(t0, &[0.5, 0.6, 0.0]);
        assert!(due_messages("Uelzen", &[], Some(&n), now).is_empty());
        // Rain only in 40 min: not yet.
        let mut v = vec![0.0; 8];
        v.push(2.0);
        let n = nowcast(t0, &v);
        assert!(due_messages("Uelzen", &[], Some(&n), now).is_empty());
    }

    #[test]
    fn warnings_from_moderate() {
        let now: Timestamp = "2026-11-09T12:00:00Z".parse().unwrap();
        let alert = |id: &str, severity: &str| Alert {
            id: id.into(),
            severity: severity.into(),
            event: "STURMBÖEN".into(),
            headline: "Amtliche WARNUNG vor STURMBÖEN".into(),
            description: "Es treten Sturmböen auf.".into(),
            instruction: None,
            onset: now,
            expires: Some(now + SignedDuration::from_hours(6)),
            source: "dwd".into(),
        };
        let m = due_messages(
            "Uelzen",
            &[alert("a", "minor"), alert("b", "severe")],
            None,
            now,
        );
        assert_eq!(m.len(), 1);
        assert_eq!(m[0].0, "alert:b");
        assert_eq!(m[0].1.priority, 5);
        assert!(m[0].1.message.contains("bis 19:00"));
    }
}
