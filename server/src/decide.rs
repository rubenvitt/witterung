//! Jev (TypeSafe), a decision model: picks which of the client's weather hints
//! matters most right now (docs/api.md, `POST /api/v1/decide`).
//!
//! The rules in the app find the hints (facts with a reason); Jev only ranks
//! them. It does not generate text: it picks one of the options it is given and
//! returns a probability for each, plus a confidence. The key stays on the
//! server, the question is fixed here, so the endpoint is no open proxy.

use std::collections::{BTreeMap, HashMap};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use axum::extract::State;
use axum::Json;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
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
const MAX_OPTION_KEY: usize = 24;
const MAX_OPTION_TEXT: usize = 300;
const MAX_STATE_BYTES: usize = 8 * 1024;
const TIMEOUT: Duration = Duration::from_secs(8);

/// The fixed question. Option keys are never sent to the model as meaning; the
/// option descriptions (from the app, German) carry it.
const INSTRUCTIONS: &str = "The state describes the current weather situation at one place in \
Germany (German text, local time Europe/Berlin). One person will see exactly one of the hints on \
a home-screen widget. Choose the hint that matters most for what this person should know or do \
in the next hours: safety first (official warnings, ice, storm, thunder), then what changes plans \
soon (rain starting within minutes, rain right now), then comfort and planning (a dry window for \
walking the dog, frost, heat, a big change tomorrow). Prefer what is imminent and certain over \
what is distant or uncertain.";

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
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct Decision {
    pub choice: String,
    pub probabilities: BTreeMap<String, f64>,
    pub confidence: f64,
    pub model: String,
}

/// Answers by request hash, in memory (lost on restart, which is fine).
#[derive(Default)]
pub struct DecisionCache {
    entries: Mutex<HashMap<[u8; 32], (Instant, Decision)>>,
}

impl DecisionCache {
    fn get(&self, key: &[u8; 32]) -> Option<Decision> {
        let entries = self.entries.lock().unwrap_or_else(|e| e.into_inner());
        entries
            .get(key)
            .filter(|(at, _)| at.elapsed() < CACHE_TTL)
            .map(|(_, d)| d.clone())
    }

    fn put(&self, key: [u8; 32], decision: Decision) {
        let mut entries = self.entries.lock().unwrap_or_else(|e| e.into_inner());
        entries.retain(|_, (at, _)| at.elapsed() < CACHE_TTL);
        if entries.len() >= CACHE_MAX {
            entries.clear();
        }
        entries.insert(key, (Instant::now(), decision));
    }
}

fn validate(req: &DecideRequest) -> AppResult<()> {
    let bad = |m: &str| Err(AppError::BadRequest(m.into()));
    if !(2..=MAX_OPTIONS).contains(&req.options.len()) {
        return bad("options: 2 bis 12 Hinweise");
    }
    for (key, text) in &req.options {
        if key.is_empty()
            || key.len() > MAX_OPTION_KEY
            || !key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
        {
            return bad("options: Schlüssel aus Buchstaben und Ziffern, höchstens 24 Zeichen");
        }
        if text.trim().is_empty() || text.chars().count() > MAX_OPTION_TEXT {
            return bad("options: Beschreibung mit 1 bis 300 Zeichen");
        }
    }
    let state_len = serde_json::to_vec(&req.state).map_or(usize::MAX, |v| v.len());
    if req.state.is_null() || state_len > MAX_STATE_BYTES {
        return bad("state: höchstens 8 KB");
    }
    Ok(())
}

/// The request body sent to Jev.
fn jev_body(model: &str, req: &DecideRequest) -> Value {
    json!({
        "model": model,
        "state": req.state,
        "questions": {
            "focus": {
                "type": "choice",
                "instructions": INSTRUCTIONS,
                "criteria": req.options,
            }
        }
    })
}

/// Reads the `focus` answer; anything else (refusal, missing option) is an error.
fn parse_answer(body: &Value, req: &DecideRequest) -> anyhow::Result<Decision> {
    let answer = &body["answers"]["focus"];
    anyhow::ensure!(
        answer["type"] == "choice",
        "Jev hat nicht gewählt: {}",
        answer["type"]
    );
    let choice = answer["choice"]
        .as_str()
        .filter(|c| req.options.contains_key(*c))
        .ok_or_else(|| anyhow::anyhow!("Jev wählte keine der Optionen"))?
        .to_owned();
    let probabilities = req
        .options
        .keys()
        .map(|k| {
            (
                k.clone(),
                answer["probabilities"][k].as_f64().unwrap_or(0.0),
            )
        })
        .collect();
    Ok(Decision {
        choice,
        probabilities,
        confidence: answer["confidence"].as_f64().unwrap_or(0.0),
        model: body["model"].as_str().unwrap_or_default().to_owned(),
    })
}

pub async fn decide(
    State(app): State<App>,
    Json(req): Json<DecideRequest>,
) -> AppResult<Json<Decision>> {
    let Some(jev) = app.config().jev.clone() else {
        return Err(AppError::Unavailable(
            "Jev ist nicht eingerichtet (WITTERUNG_JEV_KEY)".into(),
        ));
    };
    validate(&req)?;
    let body = jev_body(&jev.model, &req);
    let key: [u8; 32] = Sha256::digest(body.to_string().as_bytes()).into();
    if let Some(hit) = app.decisions().get(&key) {
        return Ok(Json(hit));
    }
    let response = app
        .http()
        .post(jev.url.clone())
        .bearer_auth(&jev.key.0)
        .timeout(TIMEOUT)
        .json(&body)
        .send()
        .await
        .map_err(|e| AppError::Upstream(format!("Jev nicht erreichbar: {e}")))?;
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
    let decision = parse_answer(&answer, &req).map_err(|e| AppError::Upstream(e.to_string()))?;
    tracing::debug!(choice = %decision.choice, confidence = decision.confidence, "jev decision");
    app.decisions().put(key, decision.clone());
    Ok(Json(decision))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn req(options: &[(&str, &str)]) -> DecideRequest {
        DecideRequest {
            state: json!({"temp_c": 8}),
            options: options
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
        }
    }

    #[test]
    fn validation() {
        assert!(validate(&req(&[
            ("rainSoon", "Regen in 10 Minuten"),
            ("walk", "Gassi")
        ]))
        .is_ok());
        assert!(validate(&req(&[("rainSoon", "Regen")])).is_err());
        assert!(validate(&req(&[("rain soon", "x"), ("walk", "y")])).is_err());
        assert!(validate(&req(&[("a", ""), ("b", "y")])).is_err());
        let long = "x".repeat(301);
        assert!(validate(&req(&[("a", &long), ("b", "y")])).is_err());
        let mut big = req(&[("a", "x"), ("b", "y")]);
        big.state = json!("y".repeat(9000));
        assert!(validate(&big).is_err());
    }

    #[test]
    fn body_has_fixed_question() {
        let body = jev_body("jev-latest", &req(&[("a", "x"), ("b", "y")]));
        assert_eq!(body["questions"]["focus"]["type"], "choice");
        assert_eq!(body["questions"]["focus"]["criteria"]["a"], "x");
        assert_eq!(body["questions"]["focus"]["instructions"], INSTRUCTIONS);
    }

    #[test]
    fn parses_choice_and_rejects_unknown() {
        let r = req(&[("rainSoon", "x"), ("walk", "y")]);
        let ok = json!({"model": "jev-1.13.0", "answers": {"focus": {
            "type": "choice", "choice": "walk", "confidence": 0.7,
            "probabilities": {"rainSoon": 0.15, "walk": 0.85}}}});
        let d = parse_answer(&ok, &r).unwrap();
        assert_eq!(d.choice, "walk");
        assert_eq!(d.probabilities["rainSoon"], 0.15);
        assert_eq!(d.model, "jev-1.13.0");
        let unknown = json!({"answers": {"focus": {"type": "choice", "choice": "other"}}});
        assert!(parse_answer(&unknown, &r).is_err());
        let refusal = json!({"answers": {"focus": {"type": "refusal"}}});
        assert!(parse_answer(&refusal, &r).is_err());
    }
}
