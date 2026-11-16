//! Jev (TypeSafe), a decision model, makes the judgement calls of the app and
//! the push (docs/api.md, `POST /api/v1/decide`):
//!
//! - `focus`: which of the app's hints matters most (ranking),
//! - `mode`: what the smart widget shows (hint, hours, days, tonight, calm),
//! - `urgency`: how pressing the situation is (refresh, Smart Stack),
//! - `sections`: which card belongs on top of the place page,
//! - `window`: the best dry window for a walk with the dog,
//! - `notify` (server only, `push.rs`): whether a push is worth an interruption.
//!
//! The rules in the app find the facts; Jev only chooses among options it is
//! given and returns probabilities. It never writes text. The key stays on
//! the server and every question is fixed here, so this is no open proxy.

use std::collections::{BTreeMap, HashMap};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use axum::extract::State;
use axum::Json;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use url::Url;

use crate::app::App;
use crate::config::Secret;
use crate::error::{AppError, AppResult};

pub const DEFAULT_URL: &str = "https://api.typesafe.ai/v1/systemone";
pub const DEFAULT_MODEL: &str = "jev-latest";

/// Same situation within this time → same answer, no new call.
const CACHE_TTL: Duration = Duration::from_secs(30 * 60);
const CACHE_MAX: usize = 512;
const MAX_OPTIONS: usize = 12;
const MAX_WINDOWS: usize = 6;
const MAX_OPTION_KEY: usize = 24;
const MAX_OPTION_TEXT: usize = 300;
const MAX_STATE_BYTES: usize = 8 * 1024;
const TIMEOUT: Duration = Duration::from_secs(8);

const CONTEXT: &str = "The state describes the current weather situation at one place in Germany \
(German text, local time Europe/Berlin) for one person who regularly walks a dog. ";

const FOCUS: &str = "One person will see exactly one of these hints on a home-screen widget. Choose \
the hint that matters most for what this person should know or do in the next hours: safety first \
(official warnings, ice, storm, thunder), then what changes plans soon (rain starting within \
minutes, rain right now), then comfort and planning (a dry window for walking the dog, frost, heat, \
a big change tomorrow). Prefer what is imminent and certain over what is distant or uncertain.";

const MODE: &str = "Which view should the smart home-screen widget show right now? Consider the \
local time of day: in the evening and at night the coming night and the morning matter more than \
the afternoon.";

const URGENCY: &str = "How pressing is the weather situation for this person right now?";

const SECTIONS: &str = "The app shows several cards for this place. Which card belongs at the top \
right now, so the person sees what matters first?";

const WINDOW: &str = "Which time window is best for a walk outside with the dog? Prefer dry, \
daylight, not too cold, not too windy; if equal, the earlier one.";

pub const NOTIFY: &str = "Should this person get a push notification on the phone right now? \
Interrupt only when it changes what they do within the next hour or concerns safety. At night \
(22–7 Uhr) only for safety. Do not interrupt for things that are merely interesting.";

fn modes() -> Value {
    json!({
        "hint": "Ein einzelner Hinweis ist jetzt wichtiger als jeder Überblick (Warnung, Regen in Kürze, Glätte, Sturm, Gewitter): ihn groß zeigen.",
        "hours": "Die nächsten Stunden ändern sich spürbar (Regen kommt oder geht, Temperatur fällt oder steigt): den Stundenverlauf zeigen.",
        "days": "Die nächsten Tage sind spannender als heute (Umschwung, Hitze, Kälte, mehrere Regentage): die Tage zeigen.",
        "tonight": "Es ist Abend oder Nacht, und die kommende Nacht und der Morgen zählen (Frost, Regen in der Nacht, kalter Morgen): Nacht und Morgen zeigen.",
        "calm": "Nichts Auffälliges: eine ruhige Übersicht mit Temperatur und Wetterlage zeigen."
    })
}

fn sections() -> Value {
    json!({
        "focus": "Hinweise mit Grund: was gerade zählt und warum.",
        "nowcast": "Regenradar der nächsten zwei Stunden.",
        "tonight": "Heute Nacht und morgen früh.",
        "hourly": "Verlauf der nächsten 48 Stunden.",
        "daily": "Die nächsten 10 Tage.",
        "details": "Aktuelle Messwerte: Wind, Böen, Feuchte, Luftdruck, Sicht.",
        "sources": "Vergleich der Wetterquellen und wie einig sie sich sind."
    })
}

fn urgency_levels() -> Value {
    json!([
        "Nichts zu tun, reine Information",
        "Gut zu wissen für heute",
        "Ändert Pläne in den nächsten Stunden",
        "Jetzt handeln oder Sicherheit betroffen"
    ])
}

#[derive(Debug, Clone)]
pub struct JevConfig {
    pub key: Secret,
    pub url: Url,
    pub model: String,
}

#[derive(Debug, Deserialize)]
pub struct DecideRequest {
    /// Compact situation built by the app (current values, next hours, warnings).
    state: Value,
    /// Hint kind → German description (title, detail, reason).
    options: BTreeMap<String, String>,
    /// Candidate dry windows for a walk, key → description.
    #[serde(default)]
    windows: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Choice {
    pub choice: String,
    pub probabilities: BTreeMap<String, f64>,
    pub confidence: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Score {
    /// 0 (nothing to do) … 3 (act now), probability-weighted.
    pub score: f64,
    pub confidence: f64,
}

/// One answer per question; a question Jev refused (or that was not asked) is `null`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Decision {
    pub model: String,
    pub focus: Option<Choice>,
    pub mode: Option<Choice>,
    pub urgency: Option<Score>,
    pub sections: Option<Choice>,
    pub window: Option<Choice>,
}

/// Raw Jev answers by request hash, in memory (lost on restart, which is fine).
#[derive(Default)]
pub struct DecisionCache {
    entries: Mutex<HashMap<[u8; 32], (Instant, Value)>>,
}

impl DecisionCache {
    fn get(&self, key: &[u8; 32]) -> Option<Value> {
        let entries = self.entries.lock().unwrap_or_else(|e| e.into_inner());
        entries
            .get(key)
            .filter(|(at, _)| at.elapsed() < CACHE_TTL)
            .map(|(_, v)| v.clone())
    }

    fn put(&self, key: [u8; 32], answer: Value) {
        let mut entries = self.entries.lock().unwrap_or_else(|e| e.into_inner());
        entries.retain(|_, (at, _)| at.elapsed() < CACHE_TTL);
        if entries.len() >= CACHE_MAX {
            entries.clear();
        }
        entries.insert(key, (Instant::now(), answer));
    }
}

fn check_map(map: &BTreeMap<String, String>, name: &str) -> AppResult<()> {
    for (key, text) in map {
        if key.is_empty()
            || key.len() > MAX_OPTION_KEY
            || !key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
        {
            return Err(AppError::BadRequest(format!(
                "{name}: Schlüssel aus Buchstaben und Ziffern, höchstens 24 Zeichen"
            )));
        }
        if text.trim().is_empty() || text.chars().count() > MAX_OPTION_TEXT {
            return Err(AppError::BadRequest(format!(
                "{name}: Beschreibung mit 1 bis 300 Zeichen"
            )));
        }
    }
    Ok(())
}

fn validate(req: &DecideRequest) -> AppResult<()> {
    if !(1..=MAX_OPTIONS).contains(&req.options.len()) {
        return Err(AppError::BadRequest("options: 1 bis 12 Hinweise".into()));
    }
    if req.windows.len() > MAX_WINDOWS {
        return Err(AppError::BadRequest(
            "windows: höchstens 6 Zeitfenster".into(),
        ));
    }
    check_map(&req.options, "options")?;
    check_map(&req.windows, "windows")?;
    let state_len = serde_json::to_vec(&req.state).map_or(usize::MAX, |v| v.len());
    if req.state.is_null() || state_len > MAX_STATE_BYTES {
        return Err(AppError::BadRequest("state: höchstens 8 KB".into()));
    }
    Ok(())
}

fn choice_q(instructions: &str, criteria: Value) -> Value {
    json!({"type": "choice", "instructions": format!("{CONTEXT}{instructions}"), "criteria": criteria})
}

/// The questions for the app: ranking only with at least two hints, the walk
/// window only with at least two candidates.
fn questions(req: &DecideRequest) -> Value {
    let mut q = Map::new();
    if req.options.len() >= 2 {
        q.insert("focus".into(), choice_q(FOCUS, json!(req.options)));
    }
    q.insert("mode".into(), choice_q(MODE, modes()));
    q.insert(
        "urgency".into(),
        json!({"type": "score", "instructions": format!("{CONTEXT}{URGENCY}"), "criteria": urgency_levels()}),
    );
    q.insert("sections".into(), choice_q(SECTIONS, sections()));
    if req.windows.len() >= 2 {
        q.insert("window".into(), choice_q(WINDOW, json!(req.windows)));
    }
    Value::Object(q)
}

/// Asks Jev (or the cache). Returns the raw response body.
pub async fn ask(app: &App, state: &Value, questions: Value) -> AppResult<Value> {
    let Some(jev) = app.config().jev.clone() else {
        return Err(AppError::Unavailable(
            "Jev ist nicht eingerichtet (WITTERUNG_JEV_KEY)".into(),
        ));
    };
    let body = json!({"model": jev.model, "state": state, "questions": questions});
    let key: [u8; 32] = Sha256::digest(body.to_string().as_bytes()).into();
    if let Some(hit) = app.decisions().get(&key) {
        return Ok(hit);
    }
    let response = app
        .http()
        .post(jev.url.clone())
        .bearer_auth(&jev.key.0)
        .timeout(TIMEOUT)
        .json(&body)
        .send()
        .await
        .map_err(|e| AppError::Upstream(format!("Jev nicht erreichbar: {}", e.without_url())))?;
    let status = response.status();
    let answer: Value = response
        .json()
        .await
        .map_err(|e| AppError::Upstream(format!("Jev-Antwort unlesbar: {e}")))?;
    if !status.is_success() {
        let message = answer["error"]["message"].as_str().unwrap_or_default();
        tracing::warn!(%status, message, "jev request failed");
        return Err(AppError::Upstream(format!("Jev antwortete mit {status}")));
    }
    app.decisions().put(key, answer.clone());
    Ok(answer)
}

/// A choice answer, only if it picked one of `allowed`.
fn parse_choice(answer: &Value, allowed: &[&str]) -> Option<Choice> {
    if answer["type"] != "choice" {
        return None;
    }
    let choice = answer["choice"].as_str().filter(|c| allowed.contains(c))?;
    Some(Choice {
        choice: choice.to_owned(),
        probabilities: allowed
            .iter()
            .map(|k| {
                (
                    (*k).to_owned(),
                    answer["probabilities"][*k].as_f64().unwrap_or(0.0),
                )
            })
            .collect(),
        confidence: answer["confidence"].as_f64().unwrap_or(0.0),
    })
}

fn parse_score(answer: &Value) -> Option<Score> {
    if answer["type"] != "score" {
        return None;
    }
    Some(Score {
        score: answer["score"].as_f64()?,
        confidence: answer["confidence"].as_f64().unwrap_or(0.0),
    })
}

fn keys(v: &Value) -> Vec<&str> {
    v.as_object()
        .map(|m| m.keys().map(String::as_str).collect())
        .unwrap_or_default()
}

fn parse(body: &Value, req: &DecideRequest) -> Decision {
    let a = &body["answers"];
    let options: Vec<&str> = req.options.keys().map(String::as_str).collect();
    let windows: Vec<&str> = req.windows.keys().map(String::as_str).collect();
    let (modes, sections) = (modes(), sections());
    Decision {
        model: body["model"].as_str().unwrap_or_default().to_owned(),
        focus: parse_choice(&a["focus"], &options),
        mode: parse_choice(&a["mode"], &keys(&modes)),
        urgency: parse_score(&a["urgency"]),
        sections: parse_choice(&a["sections"], &keys(&sections)),
        window: parse_choice(&a["window"], &windows),
    }
}

pub async fn decide(
    State(app): State<App>,
    Json(req): Json<DecideRequest>,
) -> AppResult<Json<Decision>> {
    validate(&req)?;
    let answer = ask(&app, &req.state, questions(&req)).await?;
    let decision = parse(&answer, &req);
    tracing::debug!(?decision, "jev decision");
    Ok(Json(decision))
}

/// Push gate: probability that a push is worth it, `None` when Jev is off or fails.
pub async fn notify_probability(app: &App, state: Value) -> Option<f64> {
    app.config().jev.as_ref()?;
    let q = json!({"notify": {
        "type": "noul",
        "instructions": format!("{CONTEXT}{NOTIFY}"),
        "criteria": {
            "true": "Die Nachricht ändert, was die Person in der nächsten Stunde tut, oder betrifft ihre Sicherheit.",
            "false": "Die Nachricht ist nur interessant oder kann warten, bis die Person die App öffnet."
        }
    }});
    match ask(app, &state, q).await {
        Ok(body) => body["answers"]["notify"]["noul"].as_f64(),
        Err(e) => {
            tracing::warn!(error = %e, "jev push gate unavailable, sending anyway");
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn req(options: &[(&str, &str)], windows: &[(&str, &str)]) -> DecideRequest {
        let map = |v: &[(&str, &str)]| {
            v.iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect()
        };
        DecideRequest {
            state: json!({"temp_c": 8}),
            options: map(options),
            windows: map(windows),
        }
    }

    #[test]
    fn validation() {
        assert!(validate(&req(
            &[("rainSoon", "Regen in 10 Minuten"), ("walk", "Gassi")],
            &[]
        ))
        .is_ok());
        assert!(validate(&req(&[("calm", "Ruhig")], &[])).is_ok());
        assert!(validate(&req(&[], &[])).is_err());
        assert!(validate(&req(&[("rain soon", "x"), ("walk", "y")], &[])).is_err());
        assert!(validate(&req(&[("a", ""), ("b", "y")], &[])).is_err());
        let long = "x".repeat(301);
        assert!(validate(&req(&[("a", &long), ("b", "y")], &[])).is_err());
        assert!(validate(&req(&[("a", "x")], &[("w 0", "14–16 Uhr")])).is_err());
        let mut big = req(&[("a", "x"), ("b", "y")], &[]);
        big.state = json!("y".repeat(9000));
        assert!(validate(&big).is_err());
    }

    #[test]
    fn questions_depend_on_input() {
        let one = questions(&req(&[("calm", "Ruhig")], &[("w0", "jetzt")]));
        assert!(one.get("focus").is_none());
        assert!(one.get("window").is_none());
        assert_eq!(one["mode"]["type"], "choice");
        assert_eq!(one["urgency"]["type"], "score");
        assert_eq!(
            one["sections"]["criteria"]["tonight"],
            sections()["tonight"]
        );
        let two = questions(&req(
            &[("a", "x"), ("b", "y")],
            &[("w0", "jetzt"), ("w1", "später")],
        ));
        assert_eq!(two["focus"]["criteria"]["a"], "x");
        assert_eq!(two["window"]["criteria"]["w1"], "später");
        assert!(two["focus"]["instructions"]
            .as_str()
            .unwrap()
            .contains("dog"));
    }

    #[test]
    fn parses_answers_and_drops_bad_ones() {
        let r = req(
            &[("rainSoon", "x"), ("walk", "y")],
            &[("w0", "a"), ("w1", "b")],
        );
        let body = json!({"model": "jev-1.13.0", "answers": {
            "focus": {"type": "choice", "choice": "walk", "confidence": 0.7,
                      "probabilities": {"rainSoon": 0.15, "walk": 0.85}},
            "mode": {"type": "choice", "choice": "tonight", "confidence": 0.6, "probabilities": {"tonight": 0.7}},
            "urgency": {"type": "score", "score": 1.4, "confidence": 0.5},
            "sections": {"type": "refusal"},
            "window": {"type": "choice", "choice": "w9", "confidence": 0.9}
        }});
        let d = parse(&body, &r);
        assert_eq!(d.focus.as_ref().unwrap().choice, "walk");
        assert_eq!(d.focus.as_ref().unwrap().probabilities["rainSoon"], 0.15);
        assert_eq!(d.mode.as_ref().unwrap().choice, "tonight");
        assert_eq!(d.mode.as_ref().unwrap().probabilities["calm"], 0.0);
        assert_eq!(
            d.urgency,
            Some(Score {
                score: 1.4,
                confidence: 0.5
            })
        );
        assert!(d.sections.is_none());
        assert!(d.window.is_none(), "unknown window is dropped");
        assert_eq!(d.model, "jev-1.13.0");
    }
}
