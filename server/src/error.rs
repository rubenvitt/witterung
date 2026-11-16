//! Error type of the HTTP layer and its JSON form
//! `{"error":{"code":…,"message":…}}`.

use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde_json::json;

#[derive(Debug, thiserror::Error)]
pub enum AppError {
    #[error("Anmeldung erforderlich")]
    Unauthorized,
    #[error("{0}")]
    Forbidden(String),
    #[error("{0}")]
    BadRequest(String),
    #[error("nicht gefunden")]
    NotFound,
    /// A feature that is not configured on this server.
    #[error("{0}")]
    Unavailable(String),
    /// An upstream service failed (e.g. Jev).
    #[error("{0}")]
    Upstream(String),
    #[error("interner Fehler")]
    Internal(#[from] anyhow::Error),
}

impl AppError {
    pub fn status(&self) -> StatusCode {
        match self {
            AppError::Unauthorized => StatusCode::UNAUTHORIZED,
            AppError::Forbidden(_) => StatusCode::FORBIDDEN,
            AppError::BadRequest(_) => StatusCode::BAD_REQUEST,
            AppError::NotFound => StatusCode::NOT_FOUND,
            AppError::Unavailable(_) => StatusCode::SERVICE_UNAVAILABLE,
            AppError::Upstream(_) => StatusCode::BAD_GATEWAY,
            AppError::Internal(_) => StatusCode::INTERNAL_SERVER_ERROR,
        }
    }

    pub fn code(&self) -> &'static str {
        match self {
            AppError::Unauthorized => "unauthorized",
            AppError::Forbidden(_) => "forbidden",
            AppError::BadRequest(_) => "bad_request",
            AppError::NotFound => "not_found",
            AppError::Unavailable(_) => "unavailable",
            AppError::Upstream(_) => "upstream",
            AppError::Internal(_) => "internal",
        }
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        if let AppError::Internal(e) = &self {
            tracing::error!(error = ?e, "internal error");
        }
        let body = json!({"error": {"code": self.code(), "message": self.to_string()}});
        let mut response = (self.status(), Json(body)).into_response();
        if matches!(self, AppError::Unauthorized) {
            response.headers_mut().insert(
                axum::http::header::WWW_AUTHENTICATE,
                axum::http::HeaderValue::from_static("Bearer realm=\"witterung\""),
            );
        }
        response
    }
}

pub type AppResult<T> = Result<T, AppError>;
