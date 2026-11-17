//! Live-Aktivitäten über APNs: Der Server startet, aktualisiert und beendet die
//! Aktivität auf dem iPhone, auch wenn die App nicht läuft.
//!
//! Die App meldet je Gerät ein Push-to-Start-Token und den Ort, dem die
//! Aktivität folgt (ihre erste Seite), dazu für jede laufende Aktivität das
//! Update-Token. Nach jeder Poll-Runde prüft [`evaluate`] je Gerät, was gerade
//! zu zeigen ist ([`desired`]):
//!
//! 1. eine Unwetterwarnung des DWD (ab `severe`), die läuft oder binnen einer
//!    Stunde beginnt,
//! 2. sonst Regen laut Radar: „regnet“ mit Ende, falls absehbar, oder „Regen in
//!    …“, wenn er binnen einer Stunde beginnt.
//!
//! Gibt es etwas und läuft noch keine Aktivität, geht ein Start raus, je Ereignis
//! nur einmal (eine weggewischte Aktivität kommt für denselben Schauer nicht
//! wieder). Eine laufende bekommt Updates, sobald sich etwas merklich ändert,
//! und ein Ende, wenn nichts mehr ansteht.
//!
//! Der Inhalt (`content-state`) muss zu `WeatherActivityAttributes.ContentState`
//! in der App passen (`ios/Shared/WeatherActivity.swift`); Zeiten sind
//! Unix-Sekunden, damit kein Datumsformat zwischen Server und ActivityKit steht.

use std::sync::Mutex;

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::Json;
use jiff::{SignedDuration, Timestamp};
use ring::signature::EcdsaKeyPair;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::app::{now_ms, App};
use crate::auth::Principal;
use crate::db;
use crate::error::{AppError, AppResult};
use crate::sources::dwd::{Alert, Nowcast};
use crate::sources::weatherkit::{es256_jwt, p8_key};

/// Name des Attribut-Typs in der App (Push-to-Start braucht ihn).
pub const ATTRIBUTES_TYPE: &str = "WeatherActivityAttributes";
/// Ab dieser Intensität (mm/h) gilt ein 5-min-Schritt als Regen (wie in der App).
const WET_MM_H: f64 = 0.1;
/// So weit voraus startet eine Aktivität (Regen und Warnung).
const LEAD: SignedDuration = SignedDuration::from_mins(60);
/// Ein Regen-Start gilt so lange für denselben Schauer.
const RAIN_EVENT: SignedDuration = SignedDuration::from_hours(2);
/// Ohne Update gilt eine Regen-Aktivität danach als veraltet …
const RAIN_STALE: SignedDuration = SignedDuration::from_mins(30);
/// … darum vorher auffrischen, auch wenn sich nichts geändert hat.
const REFRESH_AFTER: SignedDuration = SignedDuration::from_mins(20);
/// Kleinere Verschiebungen (s) lösen kein Update aus.
const SHIFT_S: i64 = 5 * 60;
/// APNs nimmt ein neues Provider-Token höchstens alle 20 min an, gültig ist es 60.
const JWT_MAX_AGE_S: i64 = 40 * 60;
/// Das System beendet jede Live-Aktivität nach spätestens 12 Stunden.
pub const MAX_LIFETIME: SignedDuration = SignedDuration::from_hours(12);

// MARK: Konfiguration

/// APNs-Zugang (Token-Authentifizierung mit `.p8`-Schlüssel). `Debug` verbirgt
/// den Schlüssel.
#[derive(Clone)]
pub struct ApnsConfig {
    pub key_pem: String,
    pub key_id: String,
    pub team_id: String,
    /// Bundle-ID der App.
    pub topic: String,
}

impl std::fmt::Debug for ApnsConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ApnsConfig")
            .field("key_id", &self.key_id)
            .field("team_id", &self.team_id)
            .field("topic", &self.topic)
            .finish_non_exhaustive()
    }
}

pub const DEFAULT_TOPIC: &str = "dev.rubeen.witterung";

impl ApnsConfig {
    /// Bricht beim Start ab, wenn der Schlüssel kaputt ist.
    pub fn validate(&self) -> Result<(), String> {
        p8_key(&self.key_pem, "APNs").map(|_| ())
    }
}

/// Signierter Zugang mit zwischengespeichertem Provider-Token.
pub struct Apns {
    config: ApnsConfig,
    key: EcdsaKeyPair,
    jwt: Mutex<Option<(String, i64)>>,
}

impl Apns {
    pub fn new(config: ApnsConfig) -> Result<Self, String> {
        let key = p8_key(&config.key_pem, "APNs")?;
        Ok(Self {
            config,
            key,
            jwt: Mutex::new(None),
        })
    }

    fn token(&self, now: i64) -> Result<String, String> {
        let mut cached = self.jwt.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((jwt, iat)) = cached.as_ref() {
            if now - iat < JWT_MAX_AGE_S {
                return Ok(jwt.clone());
            }
        }
        let jwt = es256_jwt(
            &self.key,
            &json!({"alg": "ES256", "kid": self.config.key_id}),
            &json!({"iss": self.config.team_id, "iat": now}),
        )?;
        *cached = Some((jwt.clone(), now));
        Ok(jwt)
    }
}

// MARK: Was gezeigt wird

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    /// Regen beginnt laut Radar binnen einer Stunde: Countdown bis Beginn.
    RainSoon,
    /// Es regnet: Countdown bis zum Ende, falls das Radar es zeigt.
    Raining,
    /// Unwetterwarnung des DWD: ab/bis.
    Warning,
}

/// `WeatherActivityAttributes.ContentState` der App.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LiveState {
    pub kind: Kind,
    /// Regen- bzw. Warnbeginn (Unix-Sekunden).
    pub starts_at: i64,
    /// Regenende bzw. Ablauf der Warnung, falls bekannt.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ends_at: Option<i64>,
    /// Stärkster Regen im Schauer (mm/h); 0 bei Warnungen.
    pub peak_mm_h: f64,
    /// Ereignis der Warnung, wie der DWD es schreibt („STURMBÖEN“).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub event: Option<String>,
    /// `severe` oder `extreme`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub severity: Option<String>,
    /// Stand der Daten (Unix-Sekunden).
    pub updated_at: i64,
}

/// Was gerade zu zeigen ist, und woran ein Ereignis wiedererkannt wird.
#[derive(Debug, Clone, PartialEq)]
pub struct Desired {
    pub state: LiveState,
    /// `alert:<id>` oder `rain`.
    pub key: String,
}

fn intensity(peak: f64) -> &'static str {
    if peak >= 4.0 {
        "Starker Regen"
    } else if peak >= 0.5 {
        "Regen"
    } else {
        "Leichter Regen"
    }
}

/// „STURMBÖEN“ → „Sturmböen“, „SCHWERES GEWITTER“ → „Schweres Gewitter“.
pub fn event_title(event: &str) -> String {
    event
        .split(' ')
        .map(|w| {
            let lower = w.to_lowercase();
            let mut chars = lower.chars();
            chars
                .next()
                .map(|c| c.to_uppercase().chain(chars).collect())
                .unwrap_or_default()
        })
        .collect::<Vec<String>>()
        .join(" ")
}

/// Was die Aktivität jetzt zeigen soll; `None` = keine Aktivität.
pub fn desired(alerts: &[Alert], nowcast: Option<&Nowcast>, now: Timestamp) -> Option<Desired> {
    let warning = alerts
        .iter()
        .filter(|a| a.severity_rank() >= 3)
        .filter(|a| a.onset <= now + LEAD && a.expires.is_none_or(|e| e > now))
        .max_by(|a, b| {
            a.severity_rank()
                .cmp(&b.severity_rank())
                .then(b.onset.cmp(&a.onset))
        });
    if let Some(a) = warning {
        return Some(Desired {
            state: LiveState {
                kind: Kind::Warning,
                starts_at: a.onset.as_second(),
                ends_at: a.expires.map(|e| e.as_second()),
                peak_mm_h: 0.0,
                event: Some(a.event.clone()),
                severity: Some(a.severity.clone()),
                updated_at: now.as_second(),
            },
            key: format!("alert:{}", a.id),
        });
    }

    let points = &nowcast?.points;
    let step = SignedDuration::from_mins(5);
    let wet = |i: usize| points[i].precip_mm_h >= WET_MM_H;
    // Der Schritt, in dem `now` liegt, und alle danach.
    let current = points.iter().position(|p| p.at + step > now)?;
    let (kind, first) = if wet(current) {
        // Beginn des laufenden Schauers, soweit das Radar zurückreicht.
        let mut first = current;
        while first > 0 && wet(first - 1) {
            first -= 1;
        }
        (Kind::Raining, first)
    } else {
        let next = (current..points.len()).find(|&i| wet(i))?;
        if points[next].at > now + LEAD {
            return None;
        }
        (Kind::RainSoon, next)
    };
    let end = (first..points.len()).find(|&i| !wet(i));
    let peak = points[first..end.unwrap_or(points.len())]
        .iter()
        .map(|p| p.precip_mm_h)
        .fold(0.0, f64::max);
    Some(Desired {
        state: LiveState {
            kind,
            starts_at: points[first].at.as_second(),
            ends_at: end.map(|i| points[i].at.as_second()),
            peak_mm_h: (peak * 10.0).round() / 10.0,
            event: None,
            severity: None,
            updated_at: now.as_second(),
        },
        key: "rain".into(),
    })
}

/// Wie dringend eine laufende Aktivität ein Update braucht.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Change {
    None,
    /// Nur auffrischen oder kleine Verschiebung: Priorität 5 (kein Budget).
    Minor,
    /// Anderer Zustand oder andere Warnung: Priorität 10, mit Hinweis.
    Major,
}

pub fn change(old: Option<&LiveState>, new: &LiveState, now: Timestamp) -> Change {
    let Some(old) = old else {
        return Change::Major;
    };
    if old.kind != new.kind || old.event != new.event || old.severity != new.severity {
        return Change::Major;
    }
    let shifted = |a: Option<i64>, b: Option<i64>| match (a, b) {
        (Some(a), Some(b)) => (a - b).abs() >= SHIFT_S,
        (a, b) => a.is_some() != b.is_some(),
    };
    if shifted(Some(old.starts_at), Some(new.starts_at))
        || shifted(old.ends_at, new.ends_at)
        || intensity(old.peak_mm_h) != intensity(new.peak_mm_h)
    {
        return Change::Minor;
    }
    let refresh =
        new.kind != Kind::Warning && now.as_second() - old.updated_at >= REFRESH_AFTER.as_secs();
    if refresh {
        Change::Minor
    } else {
        Change::None
    }
}

/// Hinweis (Banner, Sperrbildschirm) zu Start und Zustandswechsel.
pub fn alert_text(place: &str, s: &LiveState, now: Timestamp) -> (String, String) {
    let time = |t: i64| {
        Timestamp::from_second(t)
            .map(crate::sources::berlin_time)
            .unwrap_or_default()
    };
    match s.kind {
        Kind::RainSoon => {
            let mins = ((s.starts_at - now.as_second()).max(0) + 59) / 60;
            (
                format!("{place}: {} in {mins} min", intensity(s.peak_mm_h)),
                format!("Ab {} laut Radar.", time(s.starts_at)),
            )
        }
        Kind::Raining => (
            format!("{place}: {}", intensity(s.peak_mm_h)),
            match s.ends_at {
                Some(end) => format!("Endet gegen {} laut Radar.", time(end)),
                None => "Hält laut Radar mindestens zwei Stunden an.".into(),
            },
        ),
        Kind::Warning => {
            let level = if s.severity.as_deref() == Some("extreme") {
                "Extreme Unwetterwarnung"
            } else {
                "Unwetterwarnung"
            };
            let event = event_title(s.event.as_deref().unwrap_or_default());
            let when = if s.starts_at > now.as_second() {
                format!(" ab {}", time(s.starts_at))
            } else {
                String::new()
            };
            let until = s
                .ends_at
                .map(|e| format!(" bis {}", time(e)))
                .unwrap_or_default();
            (
                format!("{place}: {level}"),
                format!("{event}{when}{until}."),
            )
        }
    }
}

fn stale_date(s: &LiveState, now: Timestamp) -> Option<i64> {
    match s.kind {
        Kind::Warning => s.ends_at,
        _ => Some((now + RAIN_STALE).as_second()),
    }
}

fn relevance(s: &LiveState) -> u8 {
    match s.kind {
        Kind::Warning => 100,
        Kind::RainSoon => 80,
        Kind::Raining => 60,
    }
}

/// `aps`-Inhalt für Start, Update und Ende.
pub fn payload(
    event: &str,
    place: &db::Place,
    state: Option<&LiveState>,
    alert: bool,
    now: Timestamp,
) -> Value {
    let mut aps = json!({
        "timestamp": now.as_second(),
        "event": event,
    });
    if let Some(s) = state {
        aps["content-state"] = json!(s);
        if event != "end" {
            if let Some(stale) = stale_date(s, now) {
                aps["stale-date"] = json!(stale);
            }
            aps["relevance-score"] = json!(relevance(s));
        }
        if alert {
            let (title, body) = alert_text(&place.name, s, now);
            aps["alert"] = json!({"title": title, "body": body});
        }
    }
    if event == "start" {
        aps["attributes-type"] = json!(ATTRIBUTES_TYPE);
        aps["attributes"] = json!({
            "placeId": place.id,
            "placeName": place.name,
            "current": place.kind == "current",
        });
    }
    if event == "end" {
        aps["dismissal-date"] = json!(now.as_second());
    }
    json!({ "aps": aps })
}

// MARK: Versand

#[derive(Debug)]
enum PushError {
    /// Token ist ungültig oder abgelaufen: vergessen.
    Gone,
    Other(String),
}

async fn send(
    app: &App,
    apns: &Apns,
    token: &str,
    sandbox: bool,
    payload: &Value,
    priority: u8,
) -> Result<(), PushError> {
    let endpoints = &app.config().endpoints;
    let base = if sandbox {
        &endpoints.apns_sandbox
    } else {
        &endpoints.apns
    };
    let url = base
        .join(&format!("3/device/{token}"))
        .map_err(|e| PushError::Other(e.to_string()))?;
    let jwt = apns
        .token(Timestamp::now().as_second())
        .map_err(PushError::Other)?;
    let response = app
        .http()
        .post(url)
        .header("authorization", format!("bearer {jwt}"))
        .header("apns-push-type", "liveactivity")
        .header(
            "apns-topic",
            format!("{}.push-type.liveactivity", apns.config.topic),
        )
        .header("apns-priority", priority.to_string())
        .json(payload)
        .send()
        .await
        .map_err(|e| PushError::Other(format!("APNs nicht erreichbar: {}", e.without_url())))?;
    let status = response.status();
    if status.is_success() {
        return Ok(());
    }
    let reason = response
        .json::<Value>()
        .await
        .ok()
        .and_then(|v| v["reason"].as_str().map(str::to_owned))
        .unwrap_or_default();
    if status == reqwest::StatusCode::GONE
        || matches!(
            reason.as_str(),
            "BadDeviceToken" | "Unregistered" | "DeviceTokenNotForTopic" | "ExpiredToken"
        )
    {
        return Err(PushError::Gone);
    }
    Err(PushError::Other(format!(
        "APNs antwortet {status} {reason}"
    )))
}

/// Läuft nach jeder Poll-Runde.
pub async fn evaluate(app: &App, now: Timestamp) -> AppResult<()> {
    let Some(apns) = app.apns() else {
        return Ok(());
    };
    for reg in app.blocking(db::live_registrations).await? {
        if let Err(e) = evaluate_device(app, apns, &reg, now).await {
            tracing::warn!(device = reg.device_id, error = %e, "live activity check failed");
        }
    }
    Ok(())
}

/// Ob für dieses Ereignis schon ein Start rausging.
fn already_started(reg: &db::LiveRegistration, d: &Desired, now: Timestamp) -> bool {
    if reg.start_key.as_deref() != Some(d.key.as_str()) {
        return false;
    }
    d.key != "rain"
        || reg
            .started_at
            .is_some_and(|t| now.as_millisecond() - t < RAIN_EVENT.as_millis() as i64)
}

async fn evaluate_device(
    app: &App,
    apns: &Apns,
    reg: &db::LiveRegistration,
    now: Timestamp,
) -> AppResult<()> {
    let place = match reg.place_id {
        Some(id) => app.blocking(move |c| db::find_place(c, id)).await?,
        None => None,
    };
    let desired = match &place {
        Some(p) => {
            let (alerts, nowcast) = crate::push::feeds(app, p.id, now).await?;
            desired(&alerts, nowcast.as_ref(), now)
        }
        None => None,
    };
    let device = reg.device_id;
    let activities = app
        .blocking(move |c| db::live_activities(c, device))
        .await?;
    let mut covered = false;
    for act in activities {
        let old: Option<LiveState> = act
            .state
            .as_deref()
            .and_then(|s| serde_json::from_str(s).ok());
        let id = act.activity_id.clone();
        let (Some(p), Some(d), true, false) =
            (&place, &desired, act.place_id == reg.place_id, covered)
        else {
            // Nichts mehr zu zeigen, anderer Ort oder doppelt: beenden.
            let fallback = db::Place {
                id: act.place_id.unwrap_or_default(),
                name: String::new(),
                lat: 0.0,
                lon: 0.0,
                kind: String::new(),
                notify: false,
                last_requested_at: None,
            };
            let body = payload(
                "end",
                place.as_ref().unwrap_or(&fallback),
                old.as_ref(),
                false,
                now,
            );
            match send(app, apns, &act.token, act.sandbox, &body, 10).await {
                Ok(()) | Err(PushError::Gone) => {
                    app.blocking(move |c| db::delete_live_activity(c, device, &id))
                        .await?;
                }
                Err(PushError::Other(e)) => {
                    tracing::warn!(device, error = %e, "live activity end failed, retry next round");
                }
            }
            continue;
        };
        covered = true;
        let change = change(old.as_ref(), &d.state, now);
        if change == Change::None {
            continue;
        }
        let major = change == Change::Major;
        let body = payload("update", p, Some(&d.state), major, now);
        match send(
            app,
            apns,
            &act.token,
            act.sandbox,
            &body,
            if major { 10 } else { 5 },
        )
        .await
        {
            Ok(()) => {
                let json =
                    serde_json::to_string(&d.state).map_err(|e| AppError::Internal(e.into()))?;
                let at = now.as_millisecond();
                app.blocking(move |c| db::set_live_activity_state(c, &id, &json, at))
                    .await?;
            }
            Err(PushError::Gone) => {
                app.blocking(move |c| db::delete_live_activity(c, device, &id))
                    .await?;
            }
            Err(PushError::Other(e)) => {
                tracing::warn!(device, error = %e, "live activity update failed");
            }
        }
    }
    let (Some(p), Some(d), Some(token), false) = (&place, &desired, &reg.start_token, covered)
    else {
        return Ok(());
    };
    if already_started(reg, d, now) {
        return Ok(());
    }
    let body = payload("start", p, Some(&d.state), true, now);
    match send(app, apns, token, reg.sandbox, &body, 10).await {
        Ok(()) => {
            tracing::info!(device, place = %p.name, key = %d.key, "live activity started");
            let key = d.key.clone();
            let at = now.as_millisecond();
            app.blocking(move |c| db::mark_live_started(c, device, &key, at))
                .await?;
        }
        Err(PushError::Gone) => {
            app.blocking(move |c| db::clear_live_start_token(c, device))
                .await?;
        }
        Err(PushError::Other(e)) => {
            tracing::warn!(device, error = %e, "live activity start failed, retry next round");
        }
    }
    Ok(())
}

// MARK: API

fn device_id(principal: &Principal) -> AppResult<i64> {
    match principal {
        Principal::Device(d) => Ok(d.id),
        _ => Err(AppError::Forbidden(
            "Live-Aktivitäten gibt es nur mit Geräte-Token (iOS-App)".into(),
        )),
    }
}

/// APNs-Token sind Hex-Zeichenketten.
fn valid_token(t: &str) -> bool {
    (32..=512).contains(&t.len()) && t.bytes().all(|b| b.is_ascii_hexdigit())
}

fn valid_activity_id(id: &str) -> bool {
    (1..=64).contains(&id.len()) && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

async fn check_place(app: &App, place_id: Option<i64>) -> AppResult<()> {
    if let Some(id) = place_id {
        if app
            .blocking(move |c| db::find_place(c, id))
            .await?
            .is_none()
        {
            return Err(AppError::BadRequest("place_id: unbekannter Ort".into()));
        }
    }
    Ok(())
}

#[derive(Deserialize)]
pub struct Registration {
    /// Push-to-Start-Token; fehlt es, bleibt das gespeicherte.
    start_token: Option<String>,
    /// Ort, dem die Aktivität folgt (gespeichert oder „Mein Standort“).
    place_id: Option<i64>,
    #[serde(default)]
    sandbox: bool,
}

/// `PUT /api/v1/live-activities/registration`
pub async fn register(
    State(app): State<App>,
    principal: Principal,
    Json(r): Json<Registration>,
) -> AppResult<Json<Value>> {
    let device = device_id(&principal)?;
    if r.start_token.as_deref().is_some_and(|t| !valid_token(t)) {
        return Err(AppError::BadRequest(
            "start_token ist kein APNs-Token".into(),
        ));
    }
    check_place(&app, r.place_id).await?;
    let now = now_ms();
    app.blocking(move |c| {
        db::upsert_live_registration(
            c,
            device,
            r.start_token.as_deref(),
            r.sandbox,
            r.place_id,
            now,
        )
    })
    .await?;
    Ok(Json(json!({"apns": app.apns().is_some()})))
}

/// `DELETE /api/v1/live-activities/registration`: Live-Aktivitäten aus.
pub async fn unregister(State(app): State<App>, principal: Principal) -> AppResult<StatusCode> {
    let device = device_id(&principal)?;
    app.blocking(move |c| db::delete_live_registration(c, device))
        .await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
pub struct ActivityToken {
    token: String,
    place_id: Option<i64>,
    #[serde(default)]
    sandbox: bool,
}

/// `PUT /api/v1/live-activities/{id}`: Update-Token einer laufenden Aktivität.
pub async fn report_activity(
    State(app): State<App>,
    principal: Principal,
    Path(id): Path<String>,
    Json(t): Json<ActivityToken>,
) -> AppResult<StatusCode> {
    let device = device_id(&principal)?;
    if !valid_activity_id(&id) {
        return Err(AppError::BadRequest("ungültige Aktivitäts-ID".into()));
    }
    if !valid_token(&t.token) {
        return Err(AppError::BadRequest("token ist kein APNs-Token".into()));
    }
    check_place(&app, t.place_id).await?;
    let now = now_ms();
    let stored = app
        .blocking(move |c| {
            db::upsert_live_activity(c, &id, device, t.place_id, &t.token, t.sandbox, now)
        })
        .await?;
    if stored {
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(AppError::NotFound)
    }
}

/// `DELETE /api/v1/live-activities/{id}`: beendet oder weggewischt.
pub async fn end_activity(
    State(app): State<App>,
    principal: Principal,
    Path(id): Path<String>,
) -> AppResult<StatusCode> {
    let device = device_id(&principal)?;
    app.blocking(move |c| db::delete_live_activity(c, device, &id).map(|_| ()))
        .await?;
    Ok(StatusCode::NO_CONTENT)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sources::dwd::NowcastPoint;

    fn t(s: &str) -> Timestamp {
        s.parse().unwrap()
    }

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

    fn alert(id: &str, severity: &str, onset: Timestamp, hours: i64) -> Alert {
        Alert {
            id: id.into(),
            severity: severity.into(),
            event: "ORKANARTIGE BÖEN".into(),
            headline: "Amtliche UNWETTERWARNUNG vor ORKANARTIGEN BÖEN".into(),
            description: String::new(),
            instruction: None,
            onset,
            expires: Some(onset + SignedDuration::from_hours(hours)),
            source: "dwd".into(),
        }
    }

    #[test]
    fn rain_soon_then_raining() {
        let t0 = t("2026-11-17T12:00:00Z");
        let n = nowcast(t0, &[0.0, 0.0, 0.0, 0.3, 1.2, 5.0, 0.0, 0.0]);
        let d = desired(&[], Some(&n), t0 + SignedDuration::from_mins(2)).unwrap();
        assert_eq!(d.state.kind, Kind::RainSoon);
        assert_eq!(
            d.state.starts_at,
            (t0 + SignedDuration::from_mins(15)).as_second()
        );
        assert_eq!(
            d.state.ends_at,
            Some((t0 + SignedDuration::from_mins(30)).as_second())
        );
        assert_eq!(d.state.peak_mm_h, 5.0);
        assert_eq!(d.key, "rain");

        // Mitten im Schauer: Beginn bleibt, Countdown aufs Ende.
        let d = desired(&[], Some(&n), t0 + SignedDuration::from_mins(22)).unwrap();
        assert_eq!(d.state.kind, Kind::Raining);
        assert_eq!(
            d.state.starts_at,
            (t0 + SignedDuration::from_mins(15)).as_second()
        );
        assert_eq!(
            d.state.ends_at,
            Some((t0 + SignedDuration::from_mins(30)).as_second())
        );

        // Vorbei: nichts mehr.
        assert!(desired(&[], Some(&n), t0 + SignedDuration::from_mins(31)).is_none());
    }

    #[test]
    fn rain_beyond_an_hour_or_without_end() {
        let t0 = t("2026-11-17T12:00:00Z");
        let mut v = vec![0.0; 13];
        v.push(2.0);
        assert!(desired(&[], Some(&nowcast(t0, &v)), t0).is_none(), "65 min");
        let d = desired(&[], Some(&nowcast(t0, &[0.4; 24])), t0).unwrap();
        assert_eq!(d.state.kind, Kind::Raining);
        assert_eq!(d.state.ends_at, None);
        assert!(desired(&[], None, t0).is_none());
    }

    #[test]
    fn severe_warning_wins_moderate_does_not_count() {
        let now = t("2026-11-17T12:00:00Z");
        let rain = nowcast(now, &[1.0, 1.0, 0.0]);
        let moderate = alert("m", "moderate", now, 3);
        let d = desired(std::slice::from_ref(&moderate), Some(&rain), now).unwrap();
        assert_eq!(d.state.kind, Kind::Raining);

        let later = alert("s", "severe", now + SignedDuration::from_mins(50), 3);
        let extreme = alert("x", "extreme", now + SignedDuration::from_mins(30), 2);
        let d = desired(&[moderate, later.clone(), extreme], Some(&rain), now).unwrap();
        assert_eq!(d.key, "alert:x");
        assert_eq!(d.state.kind, Kind::Warning);
        assert_eq!(d.state.severity.as_deref(), Some("extreme"));

        // Beginnt erst in 90 min: noch nicht.
        let far = alert("f", "severe", now + SignedDuration::from_mins(90), 3);
        assert!(desired(&[far], None, now).is_none());
        // Abgelaufen: nicht mehr.
        let old = alert("o", "severe", now - SignedDuration::from_hours(4), 3);
        assert!(desired(&[old], None, now).is_none());
    }

    #[test]
    fn updates_only_on_real_changes() {
        let now = t("2026-11-17T12:00:00Z");
        let base = LiveState {
            kind: Kind::RainSoon,
            starts_at: now.as_second() + 900,
            ends_at: Some(now.as_second() + 1800),
            peak_mm_h: 1.2,
            event: None,
            severity: None,
            updated_at: now.as_second(),
        };
        let later = now + SignedDuration::from_mins(10);
        let same = LiveState {
            updated_at: later.as_second(),
            ..base.clone()
        };
        assert_eq!(change(None, &base, now), Change::Major);
        assert_eq!(change(Some(&base), &same, later), Change::None);
        let shifted = LiveState {
            starts_at: base.starts_at + 300,
            ..same.clone()
        };
        assert_eq!(change(Some(&base), &shifted, later), Change::Minor);
        let heavier = LiveState {
            peak_mm_h: 6.0,
            ..same.clone()
        };
        assert_eq!(change(Some(&base), &heavier, later), Change::Minor);
        let raining = LiveState {
            kind: Kind::Raining,
            ..same.clone()
        };
        assert_eq!(change(Some(&base), &raining, later), Change::Major);
        // Nach 20 min ohne Update: auffrischen, damit sie nicht veraltet.
        let much_later = now + SignedDuration::from_mins(21);
        assert_eq!(change(Some(&base), &same, much_later), Change::Minor);
    }

    #[test]
    fn payload_matches_the_app() {
        let now = t("2026-11-17T12:00:00Z");
        let place = db::Place {
            id: 3,
            name: "Uelzen".into(),
            lat: 52.97,
            lon: 10.56,
            kind: "saved".into(),
            notify: true,
            last_requested_at: None,
        };
        let state = LiveState {
            kind: Kind::RainSoon,
            starts_at: now.as_second() + 1080,
            ends_at: None,
            peak_mm_h: 3.0,
            event: None,
            severity: None,
            updated_at: now.as_second(),
        };
        let p = payload("start", &place, Some(&state), true, now);
        let aps = &p["aps"];
        assert_eq!(aps["event"], "start");
        assert_eq!(aps["attributes-type"], ATTRIBUTES_TYPE);
        assert_eq!(
            aps["attributes"],
            json!({"placeId": 3, "placeName": "Uelzen", "current": false})
        );
        assert_eq!(aps["content-state"]["kind"], "rain_soon");
        assert_eq!(aps["content-state"]["startsAt"], now.as_second() + 1080);
        assert_eq!(aps["content-state"]["peakMmH"], 3.0);
        assert!(aps["content-state"].get("endsAt").is_none());
        assert_eq!(aps["alert"]["title"], "Uelzen: Regen in 18 min");
        assert_eq!(aps["alert"]["body"], "Ab 13:18 laut Radar.");
        assert_eq!(aps["stale-date"], now.as_second() + 1800);

        let end = payload("end", &place, Some(&state), false, now);
        assert_eq!(end["aps"]["dismissal-date"], now.as_second());
        assert!(end["aps"].get("attributes").is_none());
        assert!(end["aps"].get("alert").is_none());
    }

    #[test]
    fn warning_text() {
        let now = t("2026-11-17T12:00:00Z");
        let s = LiveState {
            kind: Kind::Warning,
            starts_at: now.as_second() - 600,
            ends_at: Some(now.as_second() + 7 * 3600),
            peak_mm_h: 0.0,
            event: Some("ORKANARTIGE BÖEN".into()),
            severity: Some("severe".into()),
            updated_at: now.as_second(),
        };
        let (title, body) = alert_text("Uelzen", &s, now);
        assert_eq!(title, "Uelzen: Unwetterwarnung");
        assert_eq!(body, "Orkanartige Böen bis 20:00.");
    }

    #[test]
    fn tokens() {
        assert!(valid_token(&"ab12".repeat(20)));
        assert!(!valid_token("kurz"));
        assert!(!valid_token(&"zz".repeat(40)));
        assert!(valid_activity_id("7C1D5E4A-0B8F-4C51-9E0B-2B1D0A6E3F11"));
        assert!(!valid_activity_id("../x"));
    }
}
