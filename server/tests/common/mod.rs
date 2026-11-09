//! Test helpers: an in-process server driven through `tower::ServiceExt`.
#![allow(dead_code)]

use axum::body::Body;
use axum::http::{header, HeaderMap, Request, StatusCode};
use axum::Router;
use http_body_util::BodyExt;
use serde_json::Value;
use tempfile::TempDir;
use tower::ServiceExt;
use witterung::{App, Config};

pub struct TestServer {
    pub app: App,
    pub router: Router,
    pub dir: TempDir,
}

pub enum Auth<'a> {
    None,
    Cookie(&'a str),
}

pub struct TestResponse {
    pub status: StatusCode,
    pub headers: HeaderMap,
    pub body: Vec<u8>,
}

impl TestResponse {
    pub fn json(&self) -> Value {
        serde_json::from_slice(&self.body)
            .unwrap_or_else(|e| panic!("not JSON ({e}): {}", self.text()))
    }

    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.body).into_owned()
    }

    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers.get(name).and_then(|v| v.to_str().ok())
    }

    /// The value a `Set-Cookie` header gives cookie `name` (`""` = cleared).
    pub fn cookie(&self, name: &str) -> Option<String> {
        self.headers
            .get_all(header::SET_COOKIE)
            .iter()
            .filter_map(|v| v.to_str().ok())
            .find_map(|c| {
                let (k, v) = c.split(';').next()?.split_once('=')?;
                (k == name).then(|| v.to_owned())
            })
    }
}

pub fn test_config(dir: &TempDir) -> Config {
    Config::for_data_dir(dir.path().join("data"))
}

impl TestServer {
    pub fn with_config(adjust: impl FnOnce(&mut Config)) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let mut config = test_config(&dir);
        adjust(&mut config);
        let http = reqwest::Client::builder().no_proxy().build().unwrap();
        let (app, router) = witterung::build(config, http).unwrap();
        TestServer { app, router, dir }
    }

    /// Sends a request; `Host: localhost` unless the request sets one.
    pub async fn send(&self, mut req: Request<Body>) -> TestResponse {
        req.headers_mut()
            .entry(header::HOST)
            .or_insert(header::HeaderValue::from_static("localhost"));
        let response = self.router.clone().oneshot(req).await.unwrap();
        let status = response.status();
        let headers = response.headers().clone();
        let body = response
            .into_body()
            .collect()
            .await
            .unwrap()
            .to_bytes()
            .to_vec();
        TestResponse {
            status,
            headers,
            body,
        }
    }

    pub async fn get(&self, path: &str, auth: Auth<'_>) -> TestResponse {
        let mut req = Request::get(path);
        if let Auth::Cookie(c) = auth {
            req = req.header(header::COOKIE, format!("witterung_session={c}"));
        }
        self.send(req.body(Body::empty()).unwrap()).await
    }
}
