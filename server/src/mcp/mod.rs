//! MCP endpoint: Streamable HTTP under `/mcp`, hand-rolled JSON-RPC 2.0
//! (pattern taken from zunder, `crates/zunder-server/src/mcp`).
//!
//! - `POST /mcp` takes one JSON-RPC message or a batch (array). Requests get
//!   `200 application/json`; notifications and responses alone get `202`
//!   without body. There is no server-initiated stream: `GET` and `DELETE`
//!   answer `405`.
//! - Stateless: no `Mcp-Session-Id` is issued; a header sent by the client
//!   is ignored.
//! - Auth: bearer token only, either an OAuth access token of
//!   [`crate::oauth`] (claude.ai connectors and other OAuth clients) or a
//!   device token (`wt_…`, from the web app or `witterung device-add`) for
//!   clients with a fixed header such as Claude Code. Session cookies and dev
//!   auth are not accepted. A `401` names the protected resource metadata in
//!   `WWW-Authenticate` (MCP authorization).
//! - A present `Origin` header must match `WITTERUNG_PUBLIC_URL` (protection
//!   against DNS rebinding); a present `MCP-Protocol-Version` header must
//!   name a supported version.
//! - Tool failures are results with `isError: true` and a German message;
//!   protocol failures are JSON-RPC errors.

pub mod tools;

use axum::body::Bytes;
use axum::extract::rejection::BytesRejection;
use axum::extract::{DefaultBodyLimit, State};
use axum::http::header::{AUTHORIZATION, ORIGIN, WWW_AUTHENTICATE};
use axum::http::{HeaderMap, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::post;
use axum::{Json, Router};
use serde_json::{json, Map, Value};

use crate::app::App;
use crate::auth::device;
use crate::error::AppError;
use crate::oauth;

/// The protocol version this server speaks.
pub const PROTOCOL_VERSION: &str = "2025-06-18";
/// All accepted protocol versions (newest first).
pub const SUPPORTED_VERSIONS: &[&str] = &["2025-06-18", "2025-03-26"];
/// Body limit of `POST /mcp`.
pub const MCP_BODY_LIMIT: usize = 256 * 1024;

/// JSON-RPC error codes.
pub mod codes {
    pub const PARSE_ERROR: i64 = -32700;
    pub const INVALID_REQUEST: i64 = -32600;
    pub const METHOD_NOT_FOUND: i64 = -32601;
    pub const INVALID_PARAMS: i64 = -32602;
}

const INSTRUCTIONS: &str = "Witterung ist eine persönliche Wetter-App. Ein Server kombiniert \
mehrere Quellen (Open-Meteo mit den Modellen ICON-D2, ICON-EU, ECMWF IFS und GFS, Bright Sky/DWD \
MOSMIX, optional Apple WeatherKit und Pirate Weather) zu einer Konsens-Vorhersage: pro Wert der \
Median der Quellen, dazu die Spannweite (spread, [min, max]) und bei Niederschlag die Einigkeit der \
Quellen (precip_agreement_pct). Eine große Spannweite heißt: unsichere Vorhersage, das ruhig so \
sagen. Dazu kommen die aktuelle Messung der nächsten DWD-Station (now.observed), ein Radar-Nowcast \
für die nächsten 2 Stunden in 5-Minuten-Schritten (nowcast, nur Deutschland) und amtliche \
DWD-Warnungen (alerts). \
Orte: Gespeicherte Orte liefert list_places (ID, Name, Koordinaten); get_forecast und get_alerts \
nehmen place als ID oder Namen. Für andere Orte get_forecast mit lat/lon aufrufen (Koordinaten \
selbst bestimmen); solche Abfragen werden auf ≈ 2 km gerundet und 24 Stunden lang mitgepollt, aber \
nicht als Ort gespeichert. Einen Ort dauerhaft anlegen nur, wenn der Nutzer das will (create_place). \
Einheiten: Temperatur °C, Niederschlag mm (stündlich bzw. Tagessumme), Nowcast mm/h, Wind und Böen \
km/h, Windrichtung Grad (woher), Wolken, Feuchte und Wahrscheinlichkeiten in Prozent, Druck hPa. \
Zeiten sind Ortszeit Europe/Berlin mit Offset. condition ist ein englischer Code (clear, \
partly_cloudy, cloudy, fog, drizzle, rain, heavy_rain, snow, sleet, hail, thunderstorm, wind); auf \
Deutsch wiedergeben. Stündliche Werte gelten ab der genannten Stunde für eine Stunde. \
Warnungen: severity minor, moderate, severe, extreme. Quellen sind zu nennen, wenn Daten gezeigt \
werden (attribution). Abgelehnte Aufrufe kommen mit deutscher Begründung zurück.";

/// The `/mcp` route (without state).
pub fn routes() -> Router<App> {
    Router::new()
        .route("/mcp", post(handle_post))
        .layer(DefaultBodyLimit::max(MCP_BODY_LIMIT))
}

fn rpc_error(id: Value, code: i64, message: impl Into<String>) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message.into()}})
}

fn rpc_result(id: Value, result: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "result": result})
}

fn check_origin(app: &App, headers: &HeaderMap) -> Result<(), AppError> {
    let Some(origin) = headers.get(ORIGIN) else {
        return Ok(());
    };
    if origin.to_str().ok() == Some(app.config().public_origin().as_str()) {
        Ok(())
    } else {
        Err(AppError::Forbidden(
            "Origin ist für /mcp nicht erlaubt".into(),
        ))
    }
}

/// `401` with the MCP authorization challenge: `WWW-Authenticate: Bearer
/// resource_metadata="…"` plus `error="invalid_token"` when a token was
/// presented but not accepted.
fn challenge(app: &App, error: Option<&str>) -> Response {
    let mut response = AppError::Unauthorized.into_response();
    let mut value = format!(
        "Bearer resource_metadata=\"{}\"",
        oauth::resource_metadata_url(app.config())
    );
    if let Some(error) = error {
        value.push_str(&format!(", error=\"{error}\""));
    }
    if let Ok(v) = HeaderValue::from_str(&value) {
        response.headers_mut().insert(WWW_AUTHENTICATE, v);
    }
    response
}

/// Authenticates `/mcp` and returns a label of the caller for the log:
/// OAuth access tokens (`woa_…`) via the built-in authorization server,
/// device tokens (`wt_…`) like `/api` does.
async fn authenticate(app: &App, headers: &HeaderMap) -> Result<String, Response> {
    let Some(value) = headers.get(AUTHORIZATION) else {
        return Err(challenge(app, None));
    };
    let Some(token) = value
        .to_str()
        .ok()
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(str::trim)
        .filter(|t| !t.is_empty())
    else {
        return Err(challenge(app, Some("invalid_request")));
    };
    let found = if token.starts_with(oauth::ACCESS_TOKEN_PREFIX) {
        oauth::authenticate_access(app, token)
            .await
            .map(|c| c.map(|c| format!("oauth:{}", c.name)))
    } else if token.starts_with(device::TOKEN_PREFIX) {
        app.authenticate_device(token)
            .await
            .map(|d| d.map(|d| format!("device:{}", d.name)))
    } else {
        Ok(None)
    };
    match found {
        Ok(Some(caller)) => Ok(caller),
        Ok(None) => Err(challenge(app, Some("invalid_token"))),
        Err(e) => Err(e.into_response()),
    }
}

async fn handle_post(
    State(app): State<App>,
    headers: HeaderMap,
    body: Result<Bytes, BytesRejection>,
) -> Response {
    if let Err(e) = check_origin(&app, &headers) {
        return e.into_response();
    }
    let caller = match authenticate(&app, &headers).await {
        Ok(c) => c,
        Err(response) => return response,
    };
    if let Some(version) = headers.get("mcp-protocol-version") {
        let supported = version
            .to_str()
            .is_ok_and(|v| SUPPORTED_VERSIONS.contains(&v));
        if !supported {
            let message = format!(
                "Nicht unterstützte MCP-Protokollversion. Unterstützt: {}",
                SUPPORTED_VERSIONS.join(", ")
            );
            return (
                StatusCode::BAD_REQUEST,
                Json(rpc_error(Value::Null, codes::INVALID_REQUEST, message)),
            )
                .into_response();
        }
    }
    let body = match body {
        Ok(b) => b,
        Err(rejection) if rejection.status() == StatusCode::PAYLOAD_TOO_LARGE => {
            return (
                StatusCode::PAYLOAD_TOO_LARGE,
                Json(rpc_error(
                    Value::Null,
                    codes::INVALID_REQUEST,
                    "Die Anfrage ist zu groß",
                )),
            )
                .into_response()
        }
        Err(rejection) => return AppError::BadRequest(rejection.body_text()).into_response(),
    };
    let message: Value = match serde_json::from_slice(&body) {
        Ok(v) => v,
        Err(e) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(rpc_error(
                    Value::Null,
                    codes::PARSE_ERROR,
                    format!("Ungültiges JSON: {e}"),
                )),
            )
                .into_response()
        }
    };

    let reply = match message {
        Value::Array(items) if items.is_empty() => Some(rpc_error(
            Value::Null,
            codes::INVALID_REQUEST,
            "Leerer Batch",
        )),
        Value::Array(items) => {
            let mut responses = Vec::new();
            for item in items {
                if let Some(r) = handle_message(&app, &caller, item).await {
                    responses.push(r);
                }
            }
            (!responses.is_empty()).then_some(Value::Array(responses))
        }
        single => handle_message(&app, &caller, single).await,
    };
    match reply {
        Some(body) => Json(body).into_response(),
        None => StatusCode::ACCEPTED.into_response(),
    }
}

/// Handles one message; `None` for notifications and client responses.
async fn handle_message(app: &App, caller: &str, message: Value) -> Option<Value> {
    let Value::Object(obj) = message else {
        return Some(rpc_error(
            Value::Null,
            codes::INVALID_REQUEST,
            "Eine JSON-RPC-Nachricht muss ein Objekt sein",
        ));
    };
    let id = obj.get("id").cloned();
    let valid_id = matches!(id, Some(Value::String(_)) | Some(Value::Number(_)));
    let reply_id = if valid_id {
        id.clone().unwrap_or(Value::Null)
    } else {
        Value::Null
    };
    if obj.get("jsonrpc").and_then(Value::as_str) != Some("2.0") {
        return Some(rpc_error(
            reply_id,
            codes::INVALID_REQUEST,
            "jsonrpc muss \"2.0\" sein",
        ));
    }
    let Some(method) = obj.get("method") else {
        // A response from the client (we never send requests): ignore.
        if id.is_some() && (obj.contains_key("result") || obj.contains_key("error")) {
            return None;
        }
        return Some(rpc_error(reply_id, codes::INVALID_REQUEST, "method fehlt"));
    };
    let Some(method) = method.as_str() else {
        return Some(rpc_error(
            reply_id,
            codes::INVALID_REQUEST,
            "method muss ein Text sein",
        ));
    };
    let params = obj.get("params").cloned().unwrap_or(Value::Null);
    match id {
        // Notification (initialized, cancelled …): nothing to answer.
        None => None,
        Some(_) if !valid_id => Some(rpc_error(
            Value::Null,
            codes::INVALID_REQUEST,
            "id muss ein Text oder eine Zahl sein",
        )),
        Some(id) => Some(handle_request(app, caller, id, method, params).await),
    }
}

async fn handle_request(app: &App, caller: &str, id: Value, method: &str, params: Value) -> Value {
    if !(params.is_null() || params.is_object()) {
        return rpc_error(id, codes::INVALID_PARAMS, "params muss ein Objekt sein");
    }
    match method {
        "initialize" => {
            let requested = params.get("protocolVersion").and_then(Value::as_str);
            let version = requested
                .filter(|v| SUPPORTED_VERSIONS.contains(v))
                .unwrap_or(PROTOCOL_VERSION);
            rpc_result(
                id,
                json!({
                    "protocolVersion": version,
                    "capabilities": {"tools": {"listChanged": false}},
                    "serverInfo": {
                        "name": "witterung",
                        "title": "Witterung",
                        "version": env!("CARGO_PKG_VERSION"),
                    },
                    "instructions": INSTRUCTIONS,
                }),
            )
        }
        "ping" => rpc_result(id, json!({})),
        "tools/list" => rpc_result(id, tools::list()),
        "tools/call" => {
            let Some(name) = params.get("name").and_then(Value::as_str) else {
                return rpc_error(id, codes::INVALID_PARAMS, "params.name fehlt");
            };
            let args = match params.get("arguments") {
                None | Some(Value::Null) => Map::new(),
                Some(Value::Object(map)) => map.clone(),
                Some(_) => {
                    return rpc_error(
                        id,
                        codes::INVALID_PARAMS,
                        "params.arguments muss ein Objekt sein",
                    )
                }
            };
            tracing::info!(caller, tool = name, "MCP tool call");
            match tools::call(app, name, args).await {
                Some(result) => rpc_result(id, result),
                None => rpc_error(
                    id,
                    codes::INVALID_PARAMS,
                    format!("Unbekanntes Werkzeug: {name}"),
                ),
            }
        }
        other => rpc_error(
            id,
            codes::METHOD_NOT_FOUND,
            format!("Unbekannte Methode: {other}"),
        ),
    }
}
